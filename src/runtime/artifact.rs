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

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};
use sha2::{Digest, Sha256};

use super::types::{ArtifactSpec, ProblemSpec, RuntimeData};
use crate::interactive::{ProblemProgressHandle, TaskItemReport, TaskKind};
use crate::nix::BuildCommand;
use crate::runner;

static NATIVE_MODULE_TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);
const STORE_ADD_BATCH_SIZE: usize = 128;
const STORE_ADD_ARG_BYTES_LIMIT: usize = 128 * 1024;

/// Returns the Nix builds needed to realize one problem's runtime artifacts.
pub fn collect_problem_realize_builds(problem: &ProblemSpec) -> Vec<BuildCommand> {
  collect_problems_realize_builds(std::slice::from_ref(problem))
}

/// Returns deduplicated Nix builds needed to realize runtime artifacts.
pub fn collect_problems_realize_builds(problems: &[ProblemSpec]) -> Vec<BuildCommand> {
  let mut builds = Vec::new();
  for problem in problems {
    collect_problem_artifact_builds(&mut builds, problem);
  }
  dedup_builds(builds)
}

fn collect_problem_artifact_builds(builds: &mut Vec<BuildCommand>, problem: &ProblemSpec) {
  collect_artifact_builds(
    builds,
    [
      problem.validator.wasm.as_ref(),
      problem.checker.wasm.as_ref(),
      Some(&problem.judger.prepare_solution_runner),
      problem.judger.generate_outputs_runner.as_ref(),
      Some(&problem.judger.judge_runner),
    ],
  );

  for generator in problem.generators.values() {
    collect_artifact_build(builds, generator.wasm.as_ref());
  }
}

fn collect_artifact_builds<'a>(
  builds: &mut Vec<BuildCommand>,
  artifacts: impl IntoIterator<Item = Option<&'a ArtifactSpec>>,
) {
  for artifact in artifacts {
    collect_artifact_build(builds, artifact);
  }
}

fn collect_artifact_build(builds: &mut Vec<BuildCommand>, artifact: Option<&ArtifactSpec>) {
  let Some(artifact) = artifact else {
    return;
  };
  if let Some(build) = artifact_build_command(artifact) {
    builds.push(build);
  }
}

fn artifact_build_command(artifact: &ArtifactSpec) -> Option<BuildCommand> {
  if Path::new(&artifact.path).exists() {
    return None;
  }

  let installable = artifact_installable(artifact)?;
  Some(BuildCommand::new().no_link(true).installable(&installable))
}

fn artifact_installable(artifact: &ArtifactSpec) -> Option<String> {
  if let Some(drv_path) = &artifact.drv_path {
    return Some(format!("{drv_path}^*"));
  }

  Path::new(&artifact.path)
    .parent()
    .map(|parent| parent.to_string_lossy().into_owned())
}

fn dedup_builds(builds: Vec<BuildCommand>) -> Vec<BuildCommand> {
  let mut seen = std::collections::BTreeSet::new();
  let mut unique = Vec::new();
  for build in builds {
    let command = build.build_command_key();
    if seen.insert(command.clone()) {
      unique.push(build);
    }
  }
  unique
}

/// Realizes one artifact and returns the concrete path declared in metadata.
pub fn realize_artifact(artifact: &ArtifactSpec) -> Result<String> {
  if Path::new(&artifact.path).exists() {
    return Ok(artifact.path.clone());
  }

  run_artifact_build(artifact)
    .with_context(|| format!("Failed to realize artifact {}", artifact.path))?;

  if Path::new(&artifact.path).exists() {
    return Ok(artifact.path.clone());
  }

  if artifact.drv_path.is_some() {
    run_parent_build(artifact).with_context(|| {
      format!(
        "Failed to realize parent path for artifact {}",
        artifact.path
      )
    })?;
  }

  if Path::new(&artifact.path).exists() {
    Ok(artifact.path.clone())
  } else {
    bail!(
      "Artifact path {} does not exist after realization",
      artifact.path
    )
  }
}

fn run_artifact_build(artifact: &ArtifactSpec) -> Result<()> {
  let Some(build) = artifact_build_command(artifact) else {
    return Ok(());
  };
  build.run()
}

fn run_parent_build(artifact: &ArtifactSpec) -> Result<()> {
  let parent = Path::new(&artifact.path)
    .parent()
    .with_context(|| format!("Artifact path {} has no parent", artifact.path))?;
  BuildCommand::new()
    .no_link(true)
    .installable(parent.to_string_lossy().as_ref())
    .run()
}

/// Compiles a WASM module into Hull's native module cache and returns its path.
pub fn cache_native_module(module_path: &str) -> Result<String> {
  let module_bytes = fs::read(module_path)
    .with_context(|| format!("Failed to read module artifact {}", module_path))?;
  let cache_dir = native_module_cache_dir()?;

  if runner::is_precompiled(&module_bytes) {
    let module_path = Path::new(module_path);
    if module_path.starts_with(&cache_dir) {
      return Ok(module_path.to_string_lossy().into_owned());
    }
    bail!(
      "Refusing to load external precompiled module {}",
      module_path.display()
    );
  }

  fs::create_dir_all(&cache_dir).with_context(|| {
    format!(
      "Failed to create native module cache {}",
      cache_dir.display()
    )
  })?;

  let mut hasher = Sha256::new();
  hasher.update(env!("CARGO_PKG_VERSION").as_bytes());
  hasher.update(wasmtime_cache_version().as_bytes());
  hasher.update(std::env::consts::ARCH.as_bytes());
  hasher.update(std::env::consts::OS.as_bytes());
  hasher.update(&module_bytes);
  let cache_key = hasher
    .finalize()
    .as_slice()
    .iter()
    .map(|byte| format!("{byte:02x}"))
    .collect::<String>();
  let cached_path = cache_dir.join(format!("{cache_key}.cwasm"));

  if cached_path.exists() {
    return Ok(cached_path.to_string_lossy().into_owned());
  }

  let compiled_bytes = runner::compile(&module_bytes)?;
  let temp_path = cache_dir.join(format!(
    "{cache_key}.{}.{}.{}.tmp",
    std::process::id(),
    unique_temp_component(),
    NATIVE_MODULE_TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
  ));
  fs::write(&temp_path, compiled_bytes).with_context(|| {
    format!(
      "Failed to write cached native module {}",
      temp_path.display()
    )
  })?;

  match fs::rename(&temp_path, &cached_path) {
    Ok(()) => {}
    Err(err) if cached_path.exists() => {
      let _ = fs::remove_file(&temp_path);
      let _ = err;
    }
    Err(err) => {
      let _ = fs::remove_file(&temp_path);
      return Err(err).with_context(|| {
        format!(
          "Failed to move cached native module into place at {}",
          cached_path.display()
        )
      });
    }
  }

  Ok(cached_path.to_string_lossy().into_owned())
}

fn wasmtime_cache_version() -> &'static str {
  let lockfile = include_str!("../../Cargo.lock");
  let mut in_wasmtime_package = false;
  for line in lockfile.lines() {
    match line {
      "[[package]]" => in_wasmtime_package = false,
      "name = \"wasmtime\"" => in_wasmtime_package = true,
      _ if in_wasmtime_package && line.starts_with("version = ") => {
        return line.trim_start_matches("version = ").trim_matches('"');
      }
      _ => {}
    }
  }
  "unknown"
}

fn unique_temp_component() -> u128 {
  SystemTime::now()
    .duration_since(UNIX_EPOCH)
    .map(|duration| duration.as_nanos())
    .unwrap_or(0)
}

fn native_module_cache_dir() -> Result<PathBuf> {
  if let Some(cache_home) = std::env::var_os("XDG_CACHE_HOME") {
    return Ok(PathBuf::from(cache_home).join("hull").join("cwasm"));
  }

  let home =
    std::env::var_os("HOME").context("Failed to determine HOME for native module cache")?;
  Ok(
    PathBuf::from(home)
      .join(".cache")
      .join("hull")
      .join("cwasm"),
  )
}

/// Imports one path into the Nix store and returns the resulting store path.
pub fn add_path_to_store(path: &str) -> Result<String> {
  if path.starts_with("/nix/store/") {
    return Ok(path.to_string());
  }

  let output = Command::new("nix-store")
    .args(["--add", path])
    .output()
    .with_context(|| format!("Failed to add path {} to the Nix store", path))?;

  if !output.status.success() {
    bail!(
      "Failed to add path {} to the Nix store.\nStderr:\n{}",
      path,
      String::from_utf8_lossy(&output.stderr).trim()
    );
  }

  Ok(
    String::from_utf8(output.stdout)
      .context("Failed to parse nix-store output as UTF-8")?
      .trim()
      .to_string(),
  )
}

fn add_paths_to_store(paths: &[String]) -> Result<Vec<String>> {
  if paths.is_empty() {
    return Ok(Vec::new());
  }

  let output = Command::new("nix-store")
    .arg("--add")
    .args(paths)
    .output()
    .with_context(|| format!("Failed to add {} paths to the Nix store", paths.len()))?;

  if !output.status.success() {
    bail!(
      "Failed to add {} paths to the Nix store.\nStderr:\n{}",
      paths.len(),
      String::from_utf8_lossy(&output.stderr).trim()
    );
  }

  let stdout =
    String::from_utf8(output.stdout).context("Failed to parse nix-store output as UTF-8")?;
  let added = stdout
    .lines()
    .map(str::trim)
    .filter(|line| !line.is_empty())
    .map(str::to_string)
    .collect::<Vec<_>>();

  if added.len() != paths.len() {
    bail!(
      "Expected {} store paths from nix-store --add, got {}",
      paths.len(),
      added.len()
    );
  }

  Ok(added)
}

fn store_add_batches(paths: &[String]) -> Vec<&[String]> {
  let mut batches = Vec::new();
  let mut start = 0;
  let mut arg_bytes = 0;
  for (index, path) in paths.iter().enumerate() {
    let path_bytes = path.len() + 1;
    if index > start
      && (index - start >= STORE_ADD_BATCH_SIZE
        || arg_bytes + path_bytes > STORE_ADD_ARG_BYTES_LIMIT)
    {
      batches.push(&paths[start..index]);
      start = index;
      arg_bytes = 0;
    }
    arg_bytes += path_bytes;
  }
  if start < paths.len() {
    batches.push(&paths[start..]);
  }
  batches
}

fn visit_runtime_paths_mut(
  runtime: &mut RuntimeData,
  mut f: impl FnMut(&mut String) -> Result<()>,
) -> Result<()> {
  for path in runtime.checker.test_inputs.values_mut() {
    f(path)?;
  }

  for path in runtime.validator.test_inputs.values_mut() {
    f(path)?;
  }

  for test_case in runtime.test_cases.values_mut() {
    f(&mut test_case.data.input)?;
    f(&mut test_case.data.outputs)?;
  }

  for solution in runtime.solutions.values_mut() {
    for test_case_result in solution.test_case_results.values_mut() {
      f(&mut test_case_result.outputs)?;
    }

    for subtask_result in &mut solution.subtask_results {
      for test_case_result in subtask_result.test_cases.values_mut() {
        f(&mut test_case_result.outputs)?;
      }
    }
  }

  Ok(())
}

/// Rewrites runtime output paths so target packaging can consume store paths.
pub fn storeify_runtime_data(
  runtime: &mut RuntimeData,
  progress: Option<&ProblemProgressHandle>,
) -> Result<()> {
  let mut store_path_cache = HashMap::<String, String>::new();

  let mut pending_paths = Vec::<String>::new();
  visit_runtime_paths_mut(runtime, |path| {
    if path.starts_with("/nix/store/") || store_path_cache.contains_key(path) {
      return Ok(());
    }
    store_path_cache.insert(path.clone(), String::new());
    pending_paths.push(path.clone());
    Ok(())
  })?;

  let store_batches = store_add_batches(&pending_paths);
  let total_batches = store_batches.len();
  let batch_names = (0..total_batches)
    .map(|index| format!("batch {:04}", index + 1))
    .collect::<Vec<_>>();
  let progress_handle = progress.and_then(|progress| {
    (!batch_names.is_empty()).then(|| {
      progress.register_group(
        TaskKind::Artifact,
        "store import",
        batch_names.clone(),
        None,
      )
    })
  });

  for (index, batch) in store_batches.into_iter().enumerate() {
    let batch_name = &batch_names[index];
    let guard = progress_handle
      .as_ref()
      .map(|handle| handle.item(batch_name.clone()));
    let added = add_paths_to_store(batch)?;
    for (source, store_path) in batch.iter().zip(added) {
      store_path_cache.insert(source.clone(), store_path);
    }
    if let Some(guard) = guard {
      guard.finish(
        true,
        TaskItemReport {
          status: Some(format!("{} paths", batch.len())),
          ..TaskItemReport::default()
        },
      );
    }
  }

  let mut add_cached = |path: &str| -> Result<String> {
    if let Some(cached) = store_path_cache.get(path) {
      if cached.is_empty() {
        bail!("Missing store import result for path {}", path);
      }
      return Ok(cached.clone());
    }
    let added = add_path_to_store(path)?;
    store_path_cache.insert(path.to_string(), added.clone());
    Ok(added)
  };

  visit_runtime_paths_mut(runtime, |path| {
    *path = add_cached(path)?;
    Ok(())
  })?;

  Ok(())
}

#[cfg(test)]
mod tests {
  use super::*;
  use std::collections::{BTreeMap, HashSet};
  use std::thread;

  use crate::runtime::types::{
    CheckerTestSpec, JudgerSpec, ProblemSpec, ProgramSpec, ScoringMethod, SolutionSpec,
    SubtaskSpec, TestCaseSpec, ValidatorTestSpec,
  };

  fn artifact(path: &str, drv_path: Option<&str>) -> ArtifactSpec {
    ArtifactSpec {
      path: path.to_string(),
      drv_path: drv_path.map(str::to_string),
    }
  }

  fn collect_command_args(problem: &ProblemSpec) -> Vec<Vec<String>> {
    collect_problem_realize_builds(problem)
      .into_iter()
      .map(command_args)
      .collect::<Vec<_>>()
  }

  fn command_args(command: BuildCommand) -> Vec<String> {
    command
      .build_command_key()
      .into_iter()
      .map(|arg| arg.to_string_lossy().into_owned())
      .collect::<Vec<_>>()
  }

  fn assert_command_contains_installable(commands: &[Vec<String>], installable: &str) {
    assert!(
      commands
        .iter()
        .any(|command| command.iter().any(|arg| arg == installable)),
      "missing build installable {installable} in {commands:?}"
    );
  }

  #[test]
  fn native_module_temp_names_unique() {
    let cache_key = "cache-key";
    let handles = (0..32)
      .map(|_| {
        thread::spawn(move || {
          format!(
            "{cache_key}.{}.{}.{}.tmp",
            std::process::id(),
            unique_temp_component(),
            NATIVE_MODULE_TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
          )
        })
      })
      .collect::<Vec<_>>();

    let names = handles
      .into_iter()
      .map(|handle| handle.join().expect("temp name thread should not panic"))
      .collect::<Vec<_>>();
    let unique_names = names.iter().cloned().collect::<HashSet<_>>();

    assert_eq!(unique_names.len(), names.len());
  }

  #[test]
  fn store_add_batches_respect_count_and_byte_limits() {
    let short_paths = (0..(STORE_ADD_BATCH_SIZE + 1))
      .map(|index| format!("/tmp/hull/{index}"))
      .collect::<Vec<_>>();
    let short_batches = store_add_batches(&short_paths);
    assert_eq!(short_batches.len(), 2);
    assert_eq!(short_batches[0].len(), STORE_ADD_BATCH_SIZE);
    assert_eq!(short_batches[1].len(), 1);

    let long_path = format!("/tmp/hull/{}", "x".repeat(STORE_ADD_ARG_BYTES_LIMIT / 2));
    let long_paths = vec![long_path.clone(), long_path.clone(), long_path];
    let long_batches = store_add_batches(&long_paths);
    assert!(long_batches.len() > 1);
    assert!(long_batches.iter().all(|batch| {
      batch.iter().map(|path| path.len() + 1).sum::<usize>() <= STORE_ADD_ARG_BYTES_LIMIT
    }));
  }

  fn problem_with_artifacts() -> ProblemSpec {
    ProblemSpec {
      name: "aPlusB".to_string(),
      tick_limit: 1,
      memory_limit: 1,
      full_score: 1.0,
      checker: ProgramSpec {
        src: None,
        wasm: Some(artifact(
          "/missing/checker.wasm",
          Some("/nix/store/checker.drv"),
        )),
      },
      validator: ProgramSpec {
        src: None,
        wasm: Some(artifact(
          "/missing/validator.wasm",
          Some("/nix/store/validator.drv"),
        )),
      },
      generators: BTreeMap::from([(
        "gen".to_string(),
        ProgramSpec {
          src: None,
          wasm: Some(artifact(
            "/missing/gen.wasm",
            Some("/nix/store/generator.drv"),
          )),
        },
      )]),
      main_correct_solution: "std".to_string(),
      judger: JudgerSpec {
        prepare_solution_runner: artifact("/missing/prepare", Some("/nix/store/prepare.drv")),
        generate_outputs_runner: Some(artifact("/missing/generate", Some("/nix/store/genout.drv"))),
        judge_runner: artifact("/missing/judge", Some("/nix/store/judge.drv")),
      },
      test_cases: vec![TestCaseSpec {
        name: "case1".to_string(),
        input_file: None,
        tick_limit: 1,
        memory_limit: 1,
        groups: Vec::new(),
        trait_hints: BTreeMap::new(),
        generator: None,
        arguments: None,
      }],
      subtasks: vec![SubtaskSpec {
        full_score: 1.0,
        scoring_method: ScoringMethod::Min,
        traits: BTreeMap::new(),
      }],
      solutions: vec![
        SolutionSpec {
          name: "std".to_string(),
          src: "std.cpp".to_string(),
          main_correct_solution: true,
          participant_visibility: true,
        },
        SolutionSpec {
          name: "dup".to_string(),
          src: "dup.cpp".to_string(),
          main_correct_solution: false,
          participant_visibility: true,
        },
      ],
      checker_tests: vec![CheckerTestSpec {
        name: "checker".to_string(),
        output_name: "output".to_string(),
        output_solution: None,
        output_path: None,
        input_file: None,
        generator: None,
        arguments: None,
      }],
      validator_tests: vec![ValidatorTestSpec {
        name: "validator".to_string(),
        input_file: None,
        generator: None,
        arguments: None,
      }],
    }
  }

  #[test]
  fn collect_builds_all_artifacts() {
    let problem = problem_with_artifacts();
    let commands = collect_command_args(&problem);

    assert_command_contains_installable(&commands, "/nix/store/checker.drv^*");
    assert_command_contains_installable(&commands, "/nix/store/validator.drv^*");
    assert_command_contains_installable(&commands, "/nix/store/generator.drv^*");
    assert_command_contains_installable(&commands, "/nix/store/prepare.drv^*");
    assert_command_contains_installable(&commands, "/nix/store/genout.drv^*");
    assert_command_contains_installable(&commands, "/nix/store/judge.drv^*");
  }

  #[test]
  fn collect_builds_deduplicates() {
    let problem = problem_with_artifacts();
    let commands = collect_command_args(&problem);

    let judge_matches = commands
      .iter()
      .filter(|command| command.iter().any(|arg| arg == "/nix/store/judge.drv^*"))
      .count();
    assert_eq!(judge_matches, 1);
  }

  #[test]
  fn collect_builds_deduplicates_across_problems() {
    let first = problem_with_artifacts();
    let mut second = problem_with_artifacts();
    second.name = "second".to_string();
    let commands = collect_problems_realize_builds(&[first, second])
      .into_iter()
      .map(command_args)
      .collect::<Vec<_>>();

    let prepare_matches = commands
      .iter()
      .filter(|command| command.iter().any(|arg| arg == "/nix/store/prepare.drv^*"))
      .count();
    assert_eq!(prepare_matches, 1);
  }

  #[test]
  fn collect_builds_parent_fallback() {
    let mut problem = problem_with_artifacts();
    problem.validator.wasm = Some(artifact("/tmp/hull/validator/output.wasm", None));
    let commands = collect_command_args(&problem);

    assert_command_contains_installable(&commands, "/tmp/hull/validator");
  }
}
