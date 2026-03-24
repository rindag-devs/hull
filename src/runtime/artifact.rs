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

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};
use sha2::{Digest, Sha256};

use super::types::{ArtifactSpec, RuntimeData};
use crate::runner;

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
  let cache_key = format!("{:x}", hasher.finalize());
  let cached_path = cache_dir.join(format!("{cache_key}.cwasm"));

  if cached_path.exists() {
    return Ok(cached_path.to_string_lossy().into_owned());
  }

  let compiled_bytes = runner::compile(&module_bytes)?;
  let temp_path = cache_dir.join(format!("{cache_key}.{}.tmp", std::process::id()));
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
