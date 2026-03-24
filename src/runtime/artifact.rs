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

use std::path::Path;
use std::process::Command;

use anyhow::{Context, Result, bail};

use super::types::{ArtifactSpec, RuntimeData};

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
        "Failed to realize artifact {}. Stderr:\n{}",
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
        "Failed to realize artifact {}. Stderr:\n{}",
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
      "Failed to add path {} to the Nix store. Stderr:\n{}",
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

pub fn storeify_runtime_data(runtime: &mut RuntimeData) -> Result<()> {
  for path in runtime.checker.test_inputs.values_mut() {
    *path = add_path_to_store(path)?;
  }

  for path in runtime.validator.test_inputs.values_mut() {
    *path = add_path_to_store(path)?;
  }

  for test_case in runtime.test_cases.values_mut() {
    test_case.data.input = add_path_to_store(&test_case.data.input)?;
    test_case.data.outputs = add_path_to_store(&test_case.data.outputs)?;
  }

  for solution in runtime.solutions.values_mut() {
    for test_case_result in solution.test_case_results.values_mut() {
      test_case_result.outputs = add_path_to_store(&test_case_result.outputs)?;
    }

    for subtask_result in &mut solution.subtask_results {
      for test_case_result in subtask_result.test_cases.values_mut() {
        test_case_result.outputs = add_path_to_store(&test_case_result.outputs)?;
      }
    }
  }

  Ok(())
}
