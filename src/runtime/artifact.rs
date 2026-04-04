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

use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};

use super::types::{ArtifactSpec, RuntimeData};
use crate::interactive::{ProblemProgressHandle, TaskItemReport, TaskKind};
use crate::runner;

static NATIVE_MODULE_TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);
const STORE_ADD_BATCH_SIZE: usize = 128;

pub fn collect_problem_realize_builds(
  problem: &super::types::ProblemSpec,
) -> Vec<crate::nix::BuildCommand> {
  let mut builds = Vec::new();
  collect_artifact_build(&mut builds, problem.validator.wasm.as_ref());
  collect_artifact_build(&mut builds, problem.checker.wasm.as_ref());
  collect_artifact_build(&mut builds, Some(&problem.judger.generate_outputs_runner));
  collect_artifact_build(&mut builds, Some(&problem.judger.judge_runner));

  for generator in problem.generators.values() {
    collect_artifact_build(&mut builds, generator.wasm.as_ref());
  }
  for solution in &problem.solutions {
    collect_artifact_build(&mut builds, solution.prepared.executable.as_ref());
  }

  dedup_builds(builds)
}

fn collect_artifact_build(
  builds: &mut Vec<crate::nix::BuildCommand>,
  artifact: Option<&ArtifactSpec>,
) {
  let Some(artifact) = artifact else {
    return;
  };
  if Path::new(&artifact.path).exists() {
    return;
  }
  if let Some(drv_path) = &artifact.drv_path {
    builds.push(
      crate::nix::BuildCommand::new()
        .no_link(true)
        .installable(&format!("{drv_path}^*")),
    );
  } else if let Some(parent) = Path::new(&artifact.path).parent() {
    builds.push(
      crate::nix::BuildCommand::new()
        .no_link(true)
        .installable(parent.to_string_lossy().as_ref()),
    );
  }
}

fn dedup_builds(builds: Vec<crate::nix::BuildCommand>) -> Vec<crate::nix::BuildCommand> {
  let mut seen = std::collections::BTreeSet::new();
  let mut unique = Vec::new();
  for build in builds {
    let command = build.build_command_for_debug();
    if seen.insert(command.clone()) {
      unique.push(build);
    }
  }
  unique
}

pub fn realize_artifact(artifact: &ArtifactSpec) -> Result<String> {
  if Path::new(&artifact.path).exists() {
    return Ok(artifact.path.clone());
  }

  if let Some(drv_path) = &artifact.drv_path {
    let output = Command::new("nix")
      .args(["build", "--no-link", &format!("{drv_path}^*")])
      .output()
      .with_context(|| format!("Failed to realize derivation {}", drv_path))?;
    if !output.status.success() {
      bail!(
        "Failed to realize artifact {}.\nStderr:\n{}",
        artifact.path,
        String::from_utf8_lossy(&output.stderr).trim()
      );
    }
  }

  if Path::new(&artifact.path).exists() {
    Ok(artifact.path.clone())
  } else {
    let parent = Path::new(&artifact.path)
      .parent()
      .with_context(|| format!("Artifact path {} has no parent", artifact.path))?;
    let output = Command::new("nix")
      .args(["build", "--no-link", parent.to_string_lossy().as_ref()])
      .output()
      .with_context(|| format!("Failed to realize parent path {}", parent.display()))?;
    if !output.status.success() {
      bail!(
        "Failed to realize artifact {}.\nStderr:\n{}",
        artifact.path,
        String::from_utf8_lossy(&output.stderr).trim()
      );
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
}

pub fn cache_native_module(module_path: &str) -> Result<String> {
  let module_bytes = fs::read(module_path)
    .with_context(|| format!("Failed to read module artifact {}", module_path))?;

  if runner::is_precompiled(&module_bytes) {
    return Ok(module_path.to_string());
  }

  let cache_dir = native_module_cache_dir()?;
  fs::create_dir_all(&cache_dir).with_context(|| {
    format!(
      "Failed to create native module cache {}",
      cache_dir.display()
    )
  })?;

  let mut hasher = Sha256::new();
  hasher.update(env!("CARGO_PKG_VERSION").as_bytes());
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

  let total_batches = pending_paths.len().div_ceil(STORE_ADD_BATCH_SIZE);
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

  for (index, batch) in pending_paths.chunks(STORE_ADD_BATCH_SIZE).enumerate() {
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

  use crate::runtime::{
    CheckerTestSpec, JudgerSpec, PreparedSolutionSpec, ProblemSpec, ProgramSpec, SolutionSpec,
    SubtaskSpec, TestCaseSpec, ValidatorTestSpec,
  };

  fn artifact(path: &str, drv_path: Option<&str>) -> ArtifactSpec {
    ArtifactSpec {
      path: path.to_string(),
      drv_path: drv_path.map(str::to_string),
    }
  }

  #[test]
  fn native_module_temp_names_are_unique_across_threads() {
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
        generate_outputs_runner: artifact("/missing/generate", Some("/nix/store/genout.drv")),
        judge_runner: artifact("/missing/judge", Some("/nix/store/judge.drv")),
      },
      test_cases: vec![TestCaseSpec {
        name: "case1".to_string(),
        input_file: None,
        tick_limit: 1,
        memory_limit: 1,
        groups: Vec::new(),
        traits: BTreeMap::new(),
        generator: None,
        arguments: None,
      }],
      subtasks: vec![SubtaskSpec {
        full_score: 1.0,
        scoring_method: "min".to_string(),
        traits: BTreeMap::new(),
      }],
      solutions: vec![
        SolutionSpec {
          name: "std".to_string(),
          src: "std.cpp".to_string(),
          main_correct_solution: true,
          participant_visibility: true,
          prepared: PreparedSolutionSpec {
            src: "std.cpp".to_string(),
            executable: Some(artifact("/missing/std", Some("/nix/store/std.drv"))),
          },
        },
        SolutionSpec {
          name: "dup".to_string(),
          src: "dup.cpp".to_string(),
          main_correct_solution: false,
          participant_visibility: true,
          prepared: PreparedSolutionSpec {
            src: "dup.cpp".to_string(),
            executable: Some(artifact("/missing/std", Some("/nix/store/std.drv"))),
          },
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
  fn collect_builds_includes_all_runtime_artifacts() {
    let problem = problem_with_artifacts();
    let commands = collect_problem_realize_builds(&problem)
      .into_iter()
      .map(|command| command.build_command_for_debug())
      .collect::<Vec<_>>();

    assert!(commands
      .iter()
      .any(|command| command.contains("/nix/store/checker.drv^*")));
    assert!(commands
      .iter()
      .any(|command| command.contains("/nix/store/validator.drv^*")));
    assert!(commands
      .iter()
      .any(|command| command.contains("/nix/store/generator.drv^*")));
    assert!(commands
      .iter()
      .any(|command| command.contains("/nix/store/genout.drv^*")));
    assert!(commands
      .iter()
      .any(|command| command.contains("/nix/store/judge.drv^*")));
    assert!(commands
      .iter()
      .any(|command| command.contains("/nix/store/std.drv^*")));
  }

  #[test]
  fn collect_builds_deduplicates_identical_entries() {
    let problem = problem_with_artifacts();
    let commands = collect_problem_realize_builds(&problem)
      .into_iter()
      .map(|command| command.build_command_for_debug())
      .collect::<Vec<_>>();

    let std_matches = commands
      .iter()
      .filter(|command| command.contains("/nix/store/std.drv^*"))
      .count();
    assert_eq!(std_matches, 1);
  }

  #[test]
  fn collect_builds_fall_back_to_parent_path() {
    let mut problem = problem_with_artifacts();
    problem.validator.wasm = Some(artifact("/tmp/hull/validator/output.wasm", None));
    let commands = collect_problem_realize_builds(&problem)
      .into_iter()
      .map(|command| command.build_command_for_debug())
      .collect::<Vec<_>>();

    assert!(commands
      .iter()
      .any(|command| command.contains("/tmp/hull/validator")));
  }
}
