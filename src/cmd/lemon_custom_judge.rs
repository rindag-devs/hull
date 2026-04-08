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
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use clap::Parser;

use crate::runtime::bundle_judge::{
  judge_test_case_from_paths, prepare_bundle_judge_context, BundleJudgeTestCaseInput,
};
use crate::runtime::metadata::load_bundle_judge_problem_spec;

#[derive(Parser)]
/// Hidden entry point that judges one Lemon custom testcase through exported Hull artifacts.
pub struct LemonCustomJudgeOpts {
  /// Bundle root directory containing exported problem metadata and testcase assets.
  #[arg(long)]
  pub bundle_root: String,

  /// Metadata path relative to the bundle root.
  #[arg(long)]
  pub metadata_path: String,

  /// Submission source file to be judged.
  #[arg(long)]
  pub submission_file: String,

  /// Submission language identifier kept for CLI compatibility.
  #[arg(long)]
  pub submission_language: String,

  /// Relative path to the bundled Lemon-to-Hull language map.
  #[arg(long)]
  pub language_map_path: String,

  /// Testcase name passed through to the bundled judger.
  #[arg(long)]
  pub testcase_name: String,

  /// Input file path for the testcase being judged.
  #[arg(long)]
  pub input_path: String,

  /// Official data archive path for the testcase being judged.
  #[arg(long)]
  pub official_data_path: String,

  /// Tick limit forwarded to the bundled judger.
  #[arg(long)]
  pub tick_limit: u64,

  /// Memory limit forwarded to the bundled judger.
  #[arg(long)]
  pub memory_limit: u64,

  /// Synthetic participant solution name inserted into the runtime problem.
  #[arg(long)]
  pub participant_solution_name: String,

  /// Output path where the raw judge report JSON is written.
  #[arg(long)]
  pub output_path: String,

  /// Optional plain-text output path for lightweight watcher integrations.
  #[arg(long)]
  pub plain_output_path: Option<String>,
}

/// Executes one Lemon custom bundled judging request and writes the judge report.
pub fn run(opts: &LemonCustomJudgeOpts) -> Result<()> {
  let bundle_root = PathBuf::from(&opts.bundle_root);
  let output_path = PathBuf::from(&opts.output_path);
  let problem = load_bundle_judge_problem_spec(&bundle_root, &opts.metadata_path)?;

  let hull_language = resolve_submission_hull_language(
    &bundle_root,
    &opts.language_map_path,
    Path::new(&opts.submission_file),
  )?;

  let prepared = prepare_bundle_judge_context(
    &bundle_root,
    &problem,
    Path::new(&opts.submission_file),
    &hull_language,
    &opts.participant_solution_name,
  )?;
  let report = judge_test_case_from_paths(
    &prepared,
    BundleJudgeTestCaseInput {
      test_case_name: &opts.testcase_name,
      input_path: Path::new(&opts.input_path),
      official_data_path: Path::new(&opts.official_data_path),
      tick_limit: opts.tick_limit,
      memory_limit: opts.memory_limit,
      groups: Vec::new(),
      trait_hints: BTreeMap::new(),
    },
  )?;
  if let Some(parent) = output_path.parent() {
    std::fs::create_dir_all(parent)?;
  }
  std::fs::write(&output_path, serde_json::to_vec(&report)?).with_context(|| {
    format!(
      "Failed to write Lemon custom judge report to {}",
      output_path.display()
    )
  })?;
  if let Some(plain_output_path) = &opts.plain_output_path {
    let plain_output_path = PathBuf::from(plain_output_path);
    if let Some(parent) = plain_output_path.parent() {
      std::fs::create_dir_all(parent)?;
    }
    let plain_report = format!(
      "{}\n{}\n{}\n{}\n{}",
      report.tick, report.memory, report.score, report.status, report.message
    );
    std::fs::write(&plain_output_path, plain_report).with_context(|| {
      format!(
        "Failed to write Lemon custom plain judge report to {}",
        plain_output_path.display()
      )
    })?;
  }
  Ok(())
}

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct LemonLanguageMap {
  lemon_to_hull_language_map: BTreeMap<String, String>,
}

fn resolve_submission_hull_language(
  bundle_root: &Path,
  language_map_path: &str,
  submission_file: &Path,
) -> Result<String> {
  let extension = submission_file
    .extension()
    .and_then(|ext| ext.to_str())
    .with_context(|| {
      format!(
        "Submission file {} does not have a usable extension",
        submission_file.display()
      )
    })?;
  let map_path = bundle_root.join(language_map_path);
  let content = std::fs::read_to_string(&map_path)
    .with_context(|| format!("Failed to read Lemon language map {}", map_path.display()))?;
  let map: LemonLanguageMap =
    serde_json::from_str(&content).context("Failed to parse Lemon language map JSON")?;
  map
    .lemon_to_hull_language_map
    .get(extension)
    .cloned()
    .with_context(|| format!("No Hull language mapping found for extension `{extension}`"))
}
