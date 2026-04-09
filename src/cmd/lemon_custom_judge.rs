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

use crate::report::JudgeCliReport;
use crate::runtime::analysis::aggregate_subtask_results;
use crate::runtime::bundle_judge::{
  BundleJudgeTestCaseInput, judge_test_case_with_parts, load_official_data,
  prepare_bundle_judge_context,
};
use crate::runtime::custom_judge_scheduler::{
  ScheduledTestCase, SchedulerProgress, collect_runtime_traits, execute_scheduled_test_cases,
};
use crate::runtime::metadata::load_bundle_judge_problem_spec;
use crate::runtime::types::{BundleJudgeProblemSpec, JudgeReport};

#[derive(Parser)]
/// Hidden entry point that judges one bundled Lemon submission through Hull's own scheduler.
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

  /// Synthetic participant solution name inserted into the runtime problem.
  #[arg(long)]
  pub participant_solution_name: String,

  /// Number of worker threads used by Hull's scheduler.
  #[arg(long)]
  pub threads: usize,

  /// Output path where the raw aggregate judge report JSON is written.
  #[arg(long)]
  pub output_path: String,

  /// Plain-text output path for watcher integrations.
  #[arg(long)]
  pub plain_output_path: String,
}

#[derive(Clone, Debug)]
struct LemonBundleTestCase {
  scheduled: ScheduledTestCase,
  input_path: PathBuf,
  official_data_path: PathBuf,
  tick_limit: u64,
  memory_limit: u64,
  groups: Vec<String>,
}

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct LemonLanguageMap {
  lemon_to_hull_language_map: BTreeMap<String, String>,
}

/// Executes one Lemon bundled judging request and writes a single aggregate judge report.
pub fn run(opts: &LemonCustomJudgeOpts) -> Result<()> {
  let bundle_root = PathBuf::from(&opts.bundle_root);
  let output_path = PathBuf::from(&opts.output_path);
  let plain_output_path = PathBuf::from(&opts.plain_output_path);
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

  let test_cases = load_lemon_bundle_test_cases(&bundle_root, &problem)?;
  let scheduled_test_cases = test_cases
    .iter()
    .map(|test_case| test_case.scheduled.clone())
    .collect::<Vec<_>>();
  let runtime_traits = collect_runtime_traits(&scheduled_test_cases);

  let test_case_reports = execute_scheduled_test_cases(
    &scheduled_test_cases,
    &problem.subtasks,
    opts.threads,
    |_progress: SchedulerProgress| Ok(()),
    |test_case_name| {
      let test_case = test_cases
        .iter()
        .find(|test_case| test_case.scheduled.name == test_case_name)
        .with_context(|| format!("Missing Lemon bundled testcase `{test_case_name}`"))?;
      judge_test_case_with_parts(
        &prepared.workspace,
        &prepared.runtime_problem,
        &prepared.participant_solution,
        &prepared.prepared_solution,
        BundleJudgeTestCaseInput {
          test_case_name: &test_case.scheduled.name,
          input_path: &test_case.input_path,
          official_data_path: &test_case.official_data_path,
          tick_limit: test_case.tick_limit,
          memory_limit: test_case.memory_limit,
          groups: test_case.groups.clone(),
          trait_hints: test_case.scheduled.traits.clone(),
        },
      )
    },
  )?;

  let report = aggregate_lemon_report(&problem, &test_cases, &runtime_traits, &test_case_reports);
  write_lemon_report(&output_path, &plain_output_path, &report)
}

fn load_lemon_bundle_test_cases(
  bundle_root: &Path,
  problem: &BundleJudgeProblemSpec,
) -> Result<Vec<LemonBundleTestCase>> {
  problem
    .test_cases
    .iter()
    .map(|test_case| {
      let official_data_path = bundle_root.join(&test_case.name).join("official-data.tar");
      let loaded = load_official_data(&official_data_path, None).with_context(|| {
        format!(
          "Failed to read bundled official data header for Lemon testcase {}",
          official_data_path.display()
        )
      })?;
      Ok(LemonBundleTestCase {
        scheduled: ScheduledTestCase {
          name: test_case.name.clone(),
          traits: loaded.validation.traits,
        },
        input_path: bundle_root.join(&test_case.name).join("input"),
        official_data_path,
        tick_limit: test_case.tick_limit,
        memory_limit: test_case.memory_limit,
        groups: test_case.groups.clone(),
      })
    })
    .collect()
}

fn aggregate_lemon_report(
  problem: &BundleJudgeProblemSpec,
  test_cases: &[LemonBundleTestCase],
  runtime_traits: &BTreeMap<String, BTreeMap<String, bool>>,
  test_case_reports: &BTreeMap<String, JudgeReport>,
) -> JudgeReport {
  let scoring_problem = crate::runtime::types::ProblemSpec {
    name: problem.name.clone(),
    tick_limit: problem.tick_limit,
    memory_limit: problem.memory_limit,
    full_score: problem.full_score,
    checker: problem.checker.clone(),
    validator: problem.validator.clone(),
    generators: BTreeMap::new(),
    main_correct_solution: problem.main_correct_solution.clone(),
    judger: problem.judger.clone(),
    test_cases: test_cases
      .iter()
      .map(|test_case| crate::runtime::types::TestCaseSpec {
        name: test_case.scheduled.name.clone(),
        input_file: None,
        tick_limit: test_case.tick_limit,
        memory_limit: test_case.memory_limit,
        groups: test_case.groups.clone(),
        trait_hints: test_case.scheduled.traits.clone(),
        generator: None,
        arguments: None,
      })
      .collect(),
    subtasks: problem.subtasks.clone(),
    solutions: Vec::new(),
    checker_tests: Vec::new(),
    validator_tests: Vec::new(),
  };
  let subtask_reports =
    aggregate_subtask_results(&scoring_problem, test_case_reports, runtime_traits);
  let cli_report = JudgeCliReport::from_subtask_reports(
    problem.full_score,
    &problem.subtasks,
    &subtask_reports,
    test_case_reports,
  );
  let total_score = subtask_reports
    .iter()
    .map(|report| report.scaled_score)
    .sum::<f64>();
  let score = if problem.full_score > 0.0 {
    total_score / problem.full_score
  } else {
    0.0
  };
  let tick = test_case_reports
    .values()
    .map(|report| report.tick)
    .max()
    .unwrap_or(0);
  let memory = test_case_reports
    .values()
    .map(|report| report.memory)
    .max()
    .unwrap_or(0);

  JudgeReport {
    status: aggregate_top_level_status(test_case_reports),
    score,
    message: cli_report.render_human_readable(),
    tick,
    memory,
    outputs: String::new(),
  }
}

fn aggregate_top_level_status(test_case_reports: &BTreeMap<String, JudgeReport>) -> String {
  let statuses = test_case_reports
    .values()
    .map(|report| report.status.as_str())
    .collect::<Vec<_>>();
  if statuses.is_empty() {
    return "judgment_failed".to_string();
  }
  if statuses.iter().all(|status| *status == "accepted") {
    return "accepted".to_string();
  }
  for fatal in [
    "runtime_error",
    "time_limit_exceeded",
    "memory_limit_exceeded",
    "judgment_failed",
  ] {
    if statuses.contains(&fatal) {
      return fatal.to_string();
    }
  }
  if statuses.contains(&"wrong_answer") {
    return "wrong_answer".to_string();
  }
  if statuses.contains(&"partially_correct") {
    return "partially_correct".to_string();
  }
  statuses[0].to_string()
}

fn write_lemon_report(
  output_path: &Path,
  plain_output_path: &Path,
  report: &JudgeReport,
) -> Result<()> {
  if let Some(parent) = output_path.parent() {
    std::fs::create_dir_all(parent)?;
  }
  std::fs::write(output_path, serde_json::to_vec(report)?).with_context(|| {
    format!(
      "Failed to write Lemon custom judge report to {}",
      output_path.display()
    )
  })?;

  if let Some(parent) = plain_output_path.parent() {
    std::fs::create_dir_all(parent)?;
  }
  let plain_report = format!(
    "{}\n{}\n{}\n{}\n{}",
    report.tick, report.memory, report.score, report.status, report.message
  );
  std::fs::write(plain_output_path, plain_report).with_context(|| {
    format!(
      "Failed to write Lemon custom plain judge report to {}",
      plain_output_path.display()
    )
  })
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

#[cfg(test)]
mod tests {
  use std::fs;

  use super::*;
  use crate::runtime::bundle_judge::pack_official_data_tar;
  use crate::runtime::types::ValidationReport;

  #[test]
  fn loads_bundle_root_layout() {
    let root = std::env::temp_dir().join(format!(
      "hull-lemon-custom-bundle-test-{}",
      std::process::id()
    ));
    if root.exists() {
      fs::remove_dir_all(&root).expect("reset temp root");
    }
    fs::create_dir_all(&root).expect("create temp root");

    let problem: BundleJudgeProblemSpec = serde_json::from_value(serde_json::json!({
      "name": "sample",
      "tickLimit": 1000,
      "memoryLimit": 268435456,
      "fullScore": 100.0,
      "checker": { "src": null, "wasm": { "path": "/checker.wasm", "drvPath": null } },
      "validator": { "src": null, "wasm": { "path": "/validator.wasm", "drvPath": null } },
      "judger": {
        "prepareSolutionRunner": { "path": "/prepare", "drvPath": null },
        "generateOutputsRunner": { "path": "/generate", "drvPath": null },
        "judgeRunner": { "path": "/judge", "drvPath": null }
      },
      "mainCorrectSolution": "std",
      "subtasks": [
        { "fullScore": 100.0, "scoringMethod": "sum", "traits": {} }
      ],
      "solutions": [],
      "testCases": [
        {
          "name": "hand1",
          "tickLimit": 1000,
          "memoryLimit": 268435456,
          "groups": [],
          "traitHints": {}
        }
      ]
    }))
    .expect("valid problem spec");

    let case_root = root.join("hand1");
    fs::create_dir_all(&case_root).expect("create testcase root");
    fs::write(case_root.join("input"), b"1 2\n").expect("write input");

    let outputs_dir = root.join("outputs");
    fs::create_dir_all(&outputs_dir).expect("create outputs dir");
    fs::write(outputs_dir.join("answer"), b"3\n").expect("write output");
    pack_official_data_tar(
      "hand1",
      &ValidationReport {
        status: "valid".to_string(),
        message: String::new(),
        reader_trace_stacks: Vec::new(),
        reader_trace_tree: serde_json::json!({}),
        traits: BTreeMap::new(),
      },
      &outputs_dir,
      &case_root.join("official-data.tar"),
    )
    .expect("pack official data");

    let loaded = load_lemon_bundle_test_cases(&root, &problem).expect("load testcases");
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].scheduled.name, "hand1");
    assert_eq!(loaded[0].input_path, case_root.join("input"));
    assert_eq!(
      loaded[0].official_data_path,
      case_root.join("official-data.tar")
    );

    fs::remove_dir_all(&root).expect("cleanup temp root");
  }
}
