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
use std::ops::{Deref, DerefMut};
use std::path::Path;

use anyhow::{Context, Result};
use serde::de::DeserializeOwned;
use tempfile::TempDir;

use super::types::{BundleContestSpec, BundleJudgeProblemSpec, ContestSpec, ProblemSpec};
use crate::nix::{BuildCommand, get_flake_url};

/// Runtime metadata paired with the GC root that keeps its Nix paths alive.
pub struct LoadedMetadata<T> {
  value: T,
  _root: TempDir,
}

impl<T> Deref for LoadedMetadata<T> {
  type Target = T;

  fn deref(&self) -> &Self::Target {
    &self.value
  }
}

impl<T> DerefMut for LoadedMetadata<T> {
  fn deref_mut(&mut self) -> &mut Self::Target {
    &mut self.value
  }
}

fn build_metadata<T>(expr: &str, label: &str) -> Result<LoadedMetadata<T>>
where
  T: DeserializeOwned,
{
  let root = tempfile::Builder::new()
    .prefix("hull-runtime-metadata-")
    .tempdir()
    .context("Failed to create runtime metadata GC root")?;
  let out_link = root.path().join("metadata.json");
  let out_link_string = out_link
    .to_str()
    .context("Runtime metadata GC root contains non-UTF-8 characters")?;
  BuildCommand::new()
    .impure(true)
    .expr_stdin(expr)
    .out_link(out_link_string)
    .run()
    .with_context(|| format!("Failed to build {label}"))?;
  let output = fs::read_to_string(&out_link)
    .with_context(|| format!("Failed to read {label} from {}", out_link.display()))?;
  let value = serde_json::from_str(&output).with_context(|| format!("Failed to parse {label}"))?;
  Ok(LoadedMetadata { value, _root: root })
}

/// Evaluates one problem selector into runtime metadata.
pub fn load_problem_spec(problem: &str) -> Result<LoadedMetadata<ProblemSpec>> {
  let flake_ref = get_flake_url()?;
  let expr = format!(
    r#"
      let
        flake = builtins.getFlake {flake_ref};
      in
      (flake.inputs.hull.lib or flake.outputs.lib).${{builtins.currentSystem}}.runtime.problemMetadataFile flake.outputs.hullProblems.${{builtins.currentSystem}}.{problem}.config {{ }}
    "#,
    flake_ref = serde_json::to_string(&flake_ref)?,
  );
  build_metadata(&expr, "runtime problem metadata")
}

/// Evaluates one contest selector into runtime metadata.
pub fn load_contest_spec(contest: &str) -> Result<LoadedMetadata<ContestSpec>> {
  let flake_ref = get_flake_url()?;
  let expr = format!(
    r#"
      let
        flake = builtins.getFlake {flake_ref};
      in
      (flake.inputs.hull.lib or flake.outputs.lib).${{builtins.currentSystem}}.runtime.contestMetadataFile flake.outputs.hullContests.${{builtins.currentSystem}}.{contest}
    "#,
    flake_ref = serde_json::to_string(&flake_ref)?,
  );
  build_metadata(&expr, "runtime contest metadata")
}

/// Evaluates problem metadata with one source path added as an ad-hoc solution.
pub fn load_ad_hoc_problem_spec(
  problem: &str,
  src_path: &Path,
) -> Result<LoadedMetadata<ProblemSpec>> {
  let flake_ref = get_flake_url()?;
  let expr = format!(
    r#"
      let
        flake = builtins.getFlake {flake_ref};
      in
      (flake.inputs.hull.lib or flake.outputs.lib).${{builtins.currentSystem}}.runtime.adHocProblemMetadataFile flake.outputs.hullProblems.${{builtins.currentSystem}}.{problem}.config {src_path}
    "#,
    flake_ref = serde_json::to_string(&flake_ref)?,
    src_path = serde_json::to_string(&src_path.to_string_lossy().into_owned())?,
  );
  build_metadata(&expr, "ad-hoc runtime problem metadata")
}

/// Loads a contest manifest from an exported judging bundle.
pub fn load_bundle_contest_spec(bundle_root: &Path) -> Result<BundleContestSpec> {
  let manifest_path = bundle_root.join("contest.json");
  let content = fs::read_to_string(&manifest_path).with_context(|| {
    format!(
      "Failed to read bundle contest manifest {}",
      manifest_path.display()
    )
  })?;
  serde_json::from_str(&content).context("Failed to parse bundle contest manifest JSON")
}

/// Loads problem judging metadata at a bundle-relative path.
pub fn load_bundle_judge_problem_spec(
  bundle_root: &Path,
  relative_path: &str,
) -> Result<BundleJudgeProblemSpec> {
  let metadata_path = bundle_root.join(relative_path);
  let content = fs::read_to_string(&metadata_path).with_context(|| {
    format!(
      "Failed to read bundle judging problem metadata {}",
      metadata_path.display()
    )
  })?;
  serde_json::from_str(&content).context("Failed to parse bundle judging problem metadata JSON")
}
