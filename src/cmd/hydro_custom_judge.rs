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
use serde::Deserialize;
use serde_json::Value;

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
use crate::runtime::types::{BundleJudgeProblemSpec, JudgeReport, ProblemSpec, TestCaseSpec};

#[derive(Parser)]
/// Hidden entry point that judges one bundled Hydro submission through Hull's scheduler.
pub struct HydroCustomJudgeOpts {
  /// Root directory of the unpacked Hydro custom bundle.
  #[arg(long)]
  pub bundle_root: String,

  /// Relative path to bundled Hull problem metadata JSON.
  #[arg(long)]
  pub metadata_path: String,

  /// Path to the participant submission source file.
  #[arg(long)]
  pub submission_file: String,

  /// Hydro language id of the participant submission.
  #[arg(long)]
  pub submission_language: String,

  /// Relative path to the Hydro-to-Hull language map JSON.
  #[arg(long)]
  pub language_map_path: String,

  /// Participant solution label shown in Hull reports.
  #[arg(long)]
  pub participant_solution_name: String,

  /// Number of internal testcase judging threads. 0 means auto-detect.
  #[arg(long)]
  pub threads: usize,

  /// Output path for the plain report consumed by the Hydro checker.
  #[arg(long)]
  pub stdout_report_path: String,
}

#[derive(Clone, Debug)]
struct HydroBundleTestCase {
  scheduled: ScheduledTestCase,
  input_path: PathBuf,
  official_data_path: PathBuf,
  tick_limit: u64,
  memory_limit: u64,
  groups: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HydroLanguageMap {
  hydro_to_hull_language_map: Value,
}

pub fn run(opts: &HydroCustomJudgeOpts) -> Result<()> {
  let bundle_root = PathBuf::from(&opts.bundle_root);
  let problem = load_bundle_judge_problem_spec(&bundle_root, &opts.metadata_path)?;
  let hull_language = resolve_submission_hull_language(
    &bundle_root,
    &opts.language_map_path,
    &opts.submission_language,
  )?;
  let prepared = prepare_bundle_judge_context(
    &bundle_root,
    &problem,
    Path::new(&opts.submission_file),
    &hull_language,
    &opts.participant_solution_name,
  )?;

  let test_cases = load_hydro_bundle_test_cases(&bundle_root, &problem)?;
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
        .with_context(|| format!("Missing Hydro bundled testcase `{test_case_name}`"))?;
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

  let report = aggregate_hydro_report(&problem, &test_cases, &runtime_traits, &test_case_reports);
  write_hydro_reports(Path::new(&opts.stdout_report_path), &report)
}

fn load_hydro_bundle_test_cases(
  bundle_root: &Path,
  problem: &BundleJudgeProblemSpec,
) -> Result<Vec<HydroBundleTestCase>> {
  problem
    .test_cases
    .iter()
    .map(|test_case| {
      let official_data_path = bundle_root.join(&test_case.name).join("official-data.tar");
      let loaded = load_official_data(&official_data_path, None).with_context(|| {
        format!(
          "Failed to read bundled official data header for Hydro testcase {}",
          official_data_path.display()
        )
      })?;
      Ok(HydroBundleTestCase {
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

fn aggregate_hydro_report(
  problem: &BundleJudgeProblemSpec,
  test_cases: &[HydroBundleTestCase],
  runtime_traits: &BTreeMap<String, BTreeMap<String, bool>>,
  test_case_reports: &BTreeMap<String, JudgeReport>,
) -> JudgeReport {
  let scoring_problem = ProblemSpec {
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
      .map(|test_case| TestCaseSpec {
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
  let failure_details = test_case_reports.values().find_map(|report| {
    if report.status == "accepted" {
      return None;
    }
    let mut parts = Vec::new();
    parts.push(format!("status: {}", report.status));
    if !report.message.is_empty() {
      parts.push(format!("message:\n{}", report.message));
    }
    if !report.outputs.is_empty() {
      parts.push(format!("outputs:\n{}", report.outputs));
    }
    Some(parts.join("\n\n"))
  });
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
    message: match failure_details {
      Some(details) => format!(
        "{}\n\nFirst Failure Details:\n{}",
        cli_report.render_human_readable(),
        details
      ),
      None => cli_report.render_human_readable(),
    },
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

fn write_hydro_reports(stdout_report_path: &Path, report: &JudgeReport) -> Result<()> {
  if let Some(parent) = stdout_report_path.parent() {
    std::fs::create_dir_all(parent)?;
  }
  let final_score = (report.score * 100.0).round().clamp(0.0, 100.0) as i64;
  let final_message = if report.message.is_empty() {
    report.status.clone()
  } else {
    format!("{}:\n{}", report.status, report.message)
  };
  let plain_report = format!(
    "{}\n{}\n{}\n{}\n{}",
    report.tick, report.memory, final_score, report.status, final_message
  );
  std::fs::write(stdout_report_path, plain_report).with_context(|| {
    format!(
      "Failed to write Hydro custom stdout report to {}",
      stdout_report_path.display()
    )
  })
}

fn resolve_submission_hull_language(
  bundle_root: &Path,
  language_map_path: &str,
  submission_language: &str,
) -> Result<String> {
  let map_path = bundle_root.join(language_map_path);
  let content = std::fs::read_to_string(&map_path)
    .with_context(|| format!("Failed to read Hydro language map {}", map_path.display()))?;
  let map: HydroLanguageMap =
    serde_json::from_str(&content).context("Failed to parse Hydro language map JSON")?;
  let resolved = match &map.hydro_to_hull_language_map {
    Value::Object(flat_map) => flat_map
      .get(submission_language)
      .and_then(Value::as_str)
      .map(ToOwned::to_owned)
      .or_else(|| {
        submission_language
          .split_once('.')
          .and_then(|(_family, variant)| {
            flat_map
              .get(variant)
              .and_then(Value::as_str)
              .map(ToOwned::to_owned)
          })
      })
      .or_else(|| {
        flat_map
          .get("default")
          .and_then(Value::as_str)
          .map(ToOwned::to_owned)
      }),
    _ => None,
  };
  resolved.with_context(|| {
    format!(
      "No Hull language mapping found for Hydro language `{}`",
      submission_language
    )
  })
}
