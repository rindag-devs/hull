/*
  This file is part of Hull.

  Hull is free software: you can redistribute it and/or modify it under the terms of the GNU
  Lesser General Public License as published by the Free Software Foundation, either version 3 of
  the License, or (at your option) any later version.

  Hull is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser
  General Public License for more details.

  You should have received a copy of the GNU Lesser General Public License along with Hull. If
  not, see <https://www.gnu.org/licenses/>.
*/

use std::collections::BTreeMap;

use anyhow::{Context, Result};
use rayon::prelude::*;

use super::analysis::analyze_problem;
use super::artifact::storeify_runtime_data;
use super::metadata::{load_contest_spec, load_problem_spec};
use super::types::{RuntimeData, RuntimeOptions};
use super::workspace::RuntimeWorkspace;

fn workspace_flake_ref() -> Result<String> {
  let cwd = std::env::current_dir().context("Failed to determine current directory")?;
  Ok(cwd.to_string_lossy().into_owned())
}

pub fn render_runtime_json(runtime: &RuntimeData) -> Result<String> {
  serde_json::to_string(runtime).context("Failed to serialize runtime analysis JSON")
}

pub fn build_problem_target(
  problem: &str,
  target: &str,
  runtime: &RuntimeData,
  out_link: &str,
  nix_args: &[String],
) -> Result<()> {
  // Runtime analysis stores paths outside `/nix/store`; move them into the
  // store before handing the data back to Nix target evaluation.
  let flake_ref = workspace_flake_ref()?;
  let mut runtime = runtime.clone();
  storeify_runtime_data(&mut runtime)?;
  let runtime_json = render_runtime_json(&runtime)?;
  let expr = format!(
    r#"
      let
        flake = builtins.getFlake {flake_ref};
        lib = flake.inputs.hull.lib or flake.outputs.lib;
        problemConfig = flake.outputs.hullProblems.${{builtins.currentSystem}}.{problem}.config;
      in
      lib.${{builtins.currentSystem}}.runtime.buildProblemTarget problemConfig (builtins.fromJSON {runtime_json}) {target}
    "#,
    flake_ref = serde_json::to_string(&flake_ref)?,
    runtime_json = serde_json::to_string(&runtime_json)?,
    target = serde_json::to_string(target)?,
  );
  crate::nix::BuildCommand::new()
    .impure(true)
    .expr(&expr)
    .out_link(out_link)
    .extra_args(nix_args)
    .run()
}

pub fn build_contest_target(
  contest: &str,
  target: &str,
  runtime_by_problem: &BTreeMap<String, RuntimeData>,
  out_link: &str,
  nix_args: &[String],
) -> Result<()> {
  let flake_ref = workspace_flake_ref()?;
  let mut runtime_by_problem = runtime_by_problem.clone();
  for runtime in runtime_by_problem.values_mut() {
    storeify_runtime_data(runtime)?;
  }
  let runtime_json = serde_json::to_string(&runtime_by_problem)
    .context("Failed to serialize contest runtime analysis JSON")?;
  let expr = format!(
    r#"
      let
        flake = builtins.getFlake {flake_ref};
        lib = flake.inputs.hull.lib or flake.outputs.lib;
        contestConfig = flake.outputs.hullContests.${{builtins.currentSystem}}.{contest}.config;
      in
      lib.${{builtins.currentSystem}}.runtime.buildContestTarget contestConfig (builtins.fromJSON {runtime_json}) {target}
    "#,
    flake_ref = serde_json::to_string(&flake_ref)?,
    runtime_json = serde_json::to_string(&runtime_json)?,
    target = serde_json::to_string(target)?,
  );
  crate::nix::BuildCommand::new()
    .impure(true)
    .expr(&expr)
    .out_link(out_link)
    .extra_args(nix_args)
    .run()
}

pub fn build_problem(
  problem: &str,
  target: &str,
  out_link: &str,
  options: RuntimeOptions,
  nix_args: &[String],
) -> Result<()> {
  let spec = load_problem_spec(problem)?;
  let workspace =
    RuntimeWorkspace::new(std::env::temp_dir().join(format!("hull-build-{problem}")))?;
  let runtime = analyze_problem(&spec, &workspace, options)?;
  build_problem_target(problem, target, &runtime, out_link, nix_args)
}

pub fn build_contest(
  contest: &str,
  target: &str,
  out_link: &str,
  options: RuntimeOptions,
  nix_args: &[String],
) -> Result<()> {
  let contest_spec = load_contest_spec(contest)?;
  let runtime_by_problem = contest_spec
    .problems
    .par_iter()
    .map(|spec| {
      let workspace = RuntimeWorkspace::new(
        std::env::temp_dir().join(format!("hull-build-contest-{contest}-{}", spec.name)),
      )?;
      let runtime = analyze_problem(&spec, &workspace, options)?;
      Ok((spec.name.clone(), runtime))
    })
    .collect::<Result<BTreeMap<_, _>>>()?;
  build_contest_target(contest, target, &runtime_by_problem, out_link, nix_args)
}
