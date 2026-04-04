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
use std::path::Path;

use anyhow::{Context, Result};

use super::types::{ContestSpec, ProblemSpec, SelfEvalContestSpec, SelfEvalJudgeProblemSpec};
use crate::nix::{EvalCommand, get_flake_url};

pub fn load_problem_spec(problem: &str) -> Result<ProblemSpec> {
  let flake_ref = get_flake_url()?;
  let expr = format!(
    r#"
      let
        flake = builtins.getFlake {flake_ref};
      in
      builtins.toJSON ((flake.inputs.hull.lib or flake.outputs.lib).${{builtins.currentSystem}}.runtime.problemMetadata flake.outputs.hullProblems.${{builtins.currentSystem}}.{problem}.config {{ }})
    "#,
    flake_ref = serde_json::to_string(&flake_ref)?,
  );
  let output = EvalCommand::new()
    .impure(true)
    .expr_stdin(&expr)
    .run_and_capture_stdout()
    .context("Failed to execute `nix eval` for runtime problem metadata")?;

  serde_json::from_str(&output).context("Failed to parse runtime problem metadata JSON")
}

pub fn load_contest_spec(contest: &str) -> Result<ContestSpec> {
  let flake_ref = get_flake_url()?;
  let expr = format!(
    r#"
      let
        flake = builtins.getFlake {flake_ref};
      in
      builtins.toJSON ((flake.inputs.hull.lib or flake.outputs.lib).${{builtins.currentSystem}}.runtime.contestMetadata flake.outputs.hullContests.${{builtins.currentSystem}}.{contest})
    "#,
    flake_ref = serde_json::to_string(&flake_ref)?,
  );
  let output = EvalCommand::new()
    .impure(true)
    .expr_stdin(&expr)
    .run_and_capture_stdout()
    .context("Failed to execute `nix eval` for runtime contest metadata")?;

  serde_json::from_str(&output).context("Failed to parse runtime contest metadata JSON")
}

pub fn load_ad_hoc_problem_spec(problem: &str, src_path: &Path) -> Result<ProblemSpec> {
  let flake_ref = get_flake_url()?;
  let expr = format!(
    r#"
      let
        flake = builtins.getFlake {flake_ref};
      in
      builtins.toJSON ((flake.inputs.hull.lib or flake.outputs.lib).${{builtins.currentSystem}}.runtime.adHocProblemMetadata flake.outputs.hullProblems.${{builtins.currentSystem}}.{problem}.config {src_path})
    "#,
    flake_ref = serde_json::to_string(&flake_ref)?,
    src_path = serde_json::to_string(&src_path.to_string_lossy().into_owned())?,
  );
  let output = EvalCommand::new()
    .impure(true)
    .expr_stdin(&expr)
    .run_and_capture_stdout()
    .context("Failed to execute `nix eval` for ad-hoc runtime problem metadata")?;

  serde_json::from_str(&output).context("Failed to parse ad-hoc runtime problem metadata JSON")
}

pub fn load_selfeval_contest_spec(bundle_root: &Path) -> Result<SelfEvalContestSpec> {
  let manifest_path = bundle_root.join("contest.json");
  let content = fs::read_to_string(&manifest_path).with_context(|| {
    format!(
      "Failed to read selfeval manifest {}",
      manifest_path.display()
    )
  })?;
  serde_json::from_str(&content).context("Failed to parse selfeval manifest JSON")
}

pub fn load_selfeval_problem_spec(
  bundle_root: &Path,
  relative_path: &str,
) -> Result<SelfEvalJudgeProblemSpec> {
  let metadata_path = bundle_root.join(relative_path);
  let content = fs::read_to_string(&metadata_path).with_context(|| {
    format!(
      "Failed to read selfeval problem metadata {}",
      metadata_path.display()
    )
  })?;
  serde_json::from_str(&content).context("Failed to parse selfeval problem metadata JSON")
}
