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
use std::io::Write;

use anyhow::{Context, Result, bail};
use rayon::prelude::*;
use tempfile::NamedTempFile;
use tracing::info;

use super::analysis::{analyze_problem, install_with_pool};
use super::artifact::{collect_problem_realize_builds, storeify_runtime_data};
use super::metadata::{load_contest_spec, load_problem_spec};
use super::types::{RuntimeData, RuntimeOptions};
use super::workspace::RuntimeWorkspace;
use crate::interactive::ProblemProgressHandle;
use crate::interactive::{PhaseKind, TaskItemReport, TaskKind};
use crate::nix::{get_flake_url, run_build_commands};

fn prepare_runtime_store_paths(
  label: &str,
  runtime: &mut RuntimeData,
  progress: Option<&ProblemProgressHandle>,
) -> Result<()> {
  info!("Importing runtime outputs into the Nix store for {label}...");
  storeify_runtime_data(runtime, progress)
}

pub fn render_runtime_json(runtime: &RuntimeData) -> Result<String> {
  serde_json::to_string(runtime).context("Failed to serialize runtime analysis JSON")
}

fn write_runtime_json_file(runtime_json: &str) -> Result<NamedTempFile> {
  let mut file = NamedTempFile::new().context("Failed to create runtime JSON file")?;
  file
    .write_all(runtime_json.as_bytes())
    .context("Failed to write runtime JSON file")?;
  file.flush().context("Failed to flush runtime JSON file")?;
  Ok(file)
}

fn runtime_json_path(file: &NamedTempFile) -> Result<String> {
  file
    .path()
    .to_str()
    .map(ToOwned::to_owned)
    .context("Runtime JSON path contains non-UTF-8 characters")
}

pub fn build_problem_target(
  problem: &str,
  target: &str,
  runtime: &RuntimeData,
  out_link: &str,
  nix_args: &[String],
) -> Result<()> {
  let flake_ref = get_flake_url()?;
  let runtime_json = render_runtime_json(runtime)?;
  let runtime_json_file = write_runtime_json_file(&runtime_json)?;
  let runtime_json_path = runtime_json_path(&runtime_json_file)?;
  let expr = format!(
    r#"
      {{ runtimeJsonPath }}:
      let
        flake = builtins.getFlake {flake_ref};
        lib = flake.inputs.hull.lib or flake.outputs.lib;
        problemConfig = flake.outputs.hullProblems.${{builtins.currentSystem}}.{problem}.config;
        runtime = builtins.fromJSON (builtins.readFile (/. + runtimeJsonPath));
      in
      lib.${{builtins.currentSystem}}.runtime.buildProblemTarget problemConfig runtime {target}
    "#,
    flake_ref = serde_json::to_string(&flake_ref)?,
    target = serde_json::to_string(target)?,
  );
  crate::nix::BuildCommand::new()
    .impure(true)
    .expr_stdin(&expr)
    .argstr("runtimeJsonPath", &runtime_json_path)
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
  let runtime_json = serde_json::to_string(runtime_by_problem)
    .context("Failed to serialize contest runtime analysis JSON")?;
  let runtime_json_file = write_runtime_json_file(&runtime_json)?;
  let runtime_json_path = runtime_json_path(&runtime_json_file)?;
  let expr = format!(
    r#"
      {{ runtimeJsonPath }}:
      let
        flake = builtins.getFlake {flake_ref};
        lib = flake.inputs.hull.lib or flake.outputs.lib;
        contestConfig = flake.outputs.hullContests.${{builtins.currentSystem}}.{contest}.config;
        runtime = builtins.fromJSON (builtins.readFile (/. + runtimeJsonPath));
      in
      lib.${{builtins.currentSystem}}.runtime.buildContestTarget contestConfig runtime {target}
    "#,
    flake_ref = serde_json::to_string(&flake_ref)?,
    target = serde_json::to_string(target)?,
  );
  crate::nix::BuildCommand::new()
    .impure(true)
    .expr_stdin(&expr)
    .argstr("runtimeJsonPath", &runtime_json_path)
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
  let spec = {
    let _phase = options.progress.phase(
      PhaseKind::NixEval,
      format!("Loading metadata for {problem}"),
    );
    load_problem_spec(problem)?
  };

  {
    let _phase = options.progress.phase(
      PhaseKind::NixPrepare,
      format!("Realizing toolchains and prepared artifacts for {problem}"),
    );
    run_build_commands(
      collect_problem_realize_builds(&spec),
      "nix prepare for runtime artifacts",
    )?;
  }

  let workspace = RuntimeWorkspace::new()?;
  let mut runtime = {
    let _phase = options.progress.phase(
      PhaseKind::Runtime,
      "Running validators, checker tests, and solutions".to_string(),
    );
    analyze_problem(&spec, &workspace, options.clone())
      .with_context(|| format!("Runtime analysis failed for problem `{problem}`"))?
  };

  {
    let _phase = options
      .progress
      .phase(PhaseKind::NixBuild, format!("Packaging target {}", target));
    prepare_runtime_store_paths(
      &format!("problem `{problem}`"),
      &mut runtime,
      Some(&options.progress),
    )?;
    build_problem_target(problem, target, &runtime, out_link, nix_args)
  }
}

pub fn build_contest(
  contest: &str,
  target: &str,
  out_link: &str,
  options: RuntimeOptions,
  nix_args: &[String],
) -> Result<()> {
  let contest_spec = {
    let _phase = options.progress.phase(
      PhaseKind::NixEval,
      format!("Loading contest metadata for {contest}"),
    );
    load_contest_spec(contest)?
  };

  {
    let _phase = options.progress.phase(
      PhaseKind::NixPrepare,
      format!("Realizing toolchains and prepared artifacts for contest {contest}"),
    );
    run_build_commands(
      contest_spec
        .problems
        .iter()
        .flat_map(collect_problem_realize_builds)
        .collect(),
      "nix prepare for contest runtime artifacts",
    )?;
  }

  let mut runtime_by_problem = {
    let _phase = options.progress.phase(
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
    install_with_pool(options.clone(), || {
      contest_spec
        .problems
        .par_iter()
        .map(|spec| {
          if options.should_stop() {
            bail!("Contest analysis stopped after an earlier failure");
          }
          let guard = contest_handle
            .as_ref()
            .map(|handle| handle.item(spec.name.clone()));
          let workspace = RuntimeWorkspace::new()?;
          let problem_progress = options
            .progress
            .child_scope(contest)
            .child_scope(&spec.name);
          let runtime =
            analyze_problem(spec, &workspace, options.single_job_child(problem_progress))
              .with_context(|| {
                format!(
                  "Runtime analysis failed for contest `{contest}`, problem `{}`",
                  spec.name
                )
              })?;
          if let Some(guard) = guard {
            guard.finish(
              true,
              TaskItemReport {
                status: Some("accepted".to_string()),
                ..TaskItemReport::default()
              },
            );
          }
          Ok((spec.name.clone(), (workspace, runtime)))
        })
        .collect::<Result<BTreeMap<_, _>>>()
    })?
  };

  {
    let _phase = options.progress.phase(
      PhaseKind::NixBuild,
      format!("Packaging contest target {}", target),
    );
    for (problem_name, (_, runtime)) in &mut runtime_by_problem {
      let problem_progress = options.progress.child_scope(problem_name);
      prepare_runtime_store_paths(
        &format!("contest `{contest}`, problem `{problem_name}`"),
        runtime,
        Some(&problem_progress),
      )?;
    }
    build_contest_target(
      contest,
      target,
      &runtime_by_problem
        .iter()
        .map(|(name, (_, runtime))| (name.clone(), runtime.clone()))
        .collect(),
      out_link,
      nix_args,
    )
  }
}
