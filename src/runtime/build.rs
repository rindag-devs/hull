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

use super::analysis::{analyze_problem, install_with_pool};
use super::artifact::{collect_problem_realize_builds, storeify_runtime_data};
use super::metadata::{load_contest_spec, load_problem_spec};
use super::types::{RuntimeData, RuntimeOptions};
use super::workspace::RuntimeWorkspace;
use crate::interactive::{PhaseKind, TaskItemReport, TaskKind};
use crate::nix::{get_flake_url, run_build_commands};

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
  let flake_ref = get_flake_url()?;
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
  let flake_ref = get_flake_url()?;
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
  options.progress.set_phase(
    PhaseKind::NixEval,
    format!("Loading metadata for {problem}"),
  );
  if options.progress.enabled() {
    options.progress.finish();
  }
  let spec = load_problem_spec(problem)?;
  options.progress.finish_phase();

  options.progress.set_phase(
    PhaseKind::NixPrepare,
    format!("Realizing toolchains and prepared artifacts for {problem}"),
  );
  if options.progress.enabled() {
    options.progress.finish();
  }
  run_build_commands(
    collect_problem_realize_builds(&spec),
    "nix prepare for runtime artifacts",
  )?;
  options.progress.finish_phase();

  options.progress.set_phase(
    PhaseKind::Runtime,
    "Running validators, checker tests, and solutions".to_string(),
  );
  let workspace =
    RuntimeWorkspace::new(std::env::temp_dir().join(format!("hull-build-{problem}")))?;
  let runtime = analyze_problem(&spec, &workspace, options.clone())?;
  options.progress.finish_phase();

  options
    .progress
    .set_phase(PhaseKind::NixBuild, format!("Packaging target {}", target));
  if options.progress.enabled() {
    options.progress.finish();
  }
  let result = build_problem_target(problem, target, &runtime, out_link, nix_args);
  options.progress.finish_phase();
  result
}

pub fn build_contest(
  contest: &str,
  target: &str,
  out_link: &str,
  options: RuntimeOptions,
  nix_args: &[String],
) -> Result<()> {
  options.progress.set_phase(
    PhaseKind::NixEval,
    format!("Loading contest metadata for {contest}"),
  );
  if options.progress.enabled() {
    options.progress.finish();
  }
  let contest_spec = load_contest_spec(contest)?;
  options.progress.finish_phase();

  options.progress.set_phase(
    PhaseKind::NixPrepare,
    format!("Realizing toolchains and prepared artifacts for contest {contest}"),
  );
  if options.progress.enabled() {
    options.progress.finish();
  }
  run_build_commands(
    contest_spec
      .problems
      .iter()
      .flat_map(collect_problem_realize_builds)
      .collect(),
    "nix prepare for contest runtime artifacts",
  )?;
  options.progress.finish_phase();

  options.progress.set_phase(
    PhaseKind::Runtime,
    format!("Running analysis for contest {}", contest),
  );
  options.progress.set_title("Contest", contest);
  let contest_handle = if contest_spec.problems.is_empty() {
    None
  } else {
    Some(options.progress.register_group(
      TaskKind::Problem,
      contest,
      contest_spec.problems.iter().map(|spec| spec.name.clone()),
      None,
    ))
  };
  let runtime_by_problem = install_with_pool(options.clone(), || {
    contest_spec
      .problems
      .par_iter()
      .map(|spec| {
        if let Some(handle) = &contest_handle {
          handle.start_item(&spec.name);
        }
        let workspace = RuntimeWorkspace::new(
          std::env::temp_dir().join(format!("hull-build-contest-{contest}-{}", spec.name)),
        )?;
        let runtime = analyze_problem(
          spec,
          &workspace,
          RuntimeOptions::new(Some(1)).with_progress(options.progress.child_scope(&spec.name)),
        )?;
        if let Some(handle) = &contest_handle {
          handle.finish_item_with_report(
            &spec.name,
            true,
            TaskItemReport {
              status: Some("accepted".to_string()),
              ..TaskItemReport::default()
            },
          );
        }
        Ok((spec.name.clone(), runtime))
      })
      .collect::<Result<BTreeMap<_, _>>>()
  })?;
  options.progress.finish_phase();
  options.progress.set_phase(
    PhaseKind::NixBuild,
    format!("Packaging contest target {}", target),
  );
  if options.progress.enabled() {
    options.progress.finish();
  }
  let result = build_contest_target(contest, target, &runtime_by_problem, out_link, nix_args);
  options.progress.finish_phase();
  result
}
