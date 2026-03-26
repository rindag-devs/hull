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
use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Parser;
use comfy_table::presets::UTF8_FULL;
use comfy_table::{Cell, Color, Table};
use serde::{Deserialize, Serialize};

use crate::interactive;
use crate::runtime::{analyze_problem, load_ad_hoc_problem_spec, RuntimeOptions, RuntimeWorkspace};
use crate::utils::{format_size, format_tick, to_title_case};

#[derive(Parser)]
pub struct JudgeOpts {
  /// Path to the source file to judge.
  pub src_path: String,

  /// The problem to build, e.g., "aPlusB".
  #[arg(long, short, default_value = "default")]
  pub problem: String,

  /// Output the result in JSON format.
  #[arg(long)]
  pub json: bool,
}

#[derive(Deserialize, Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct JudgeReport {
  score: f64,
  full_score: f64,
  subtask_results: Vec<SubtaskResult>,
  test_case_results: HashMap<String, TestCaseResult>,
}

#[derive(Deserialize, Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct SubtaskResult {
  full_score: f64,
  scaled_score: f64,
  statuses: Vec<String>,
}

#[derive(Deserialize, Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct TestCaseResult {
  status: String,
  score: f64,
  tick: u64,
  memory: u64,
}

/// Determines the overall status for a subtask based on its test cases.
/// Logic: If empty, "N/A". If any non-"accepted", return the first one. Otherwise, "accepted".
fn get_subtask_status(statuses: &[String]) -> String {
  if statuses.is_empty() {
    return "N/A".to_string();
  }
  statuses
    .iter()
    .find(|s| *s != "accepted")
    .cloned()
    .unwrap_or_else(|| "accepted".to_string())
}

/// Applies color to a status string based on predefined rules.
fn colorize_status(status: &str, text: &str) -> Cell {
  match status {
    "accepted" => Cell::new(text).fg(Color::Green),
    "wrong_answer" => Cell::new(text).fg(Color::Red),
    "partially_correct" => Cell::new(text).fg(Color::Cyan),
    "runtime_error" => Cell::new(text).fg(Color::Magenta),
    "time_limit_exceeded" | "memory_limit_exceeded" => Cell::new(text).fg(Color::Yellow),
    "internal_error" => Cell::new(text).fg(Color::Grey),
    _ => Cell::new(text), // For "N/A" or other statuses
  }
}

/// Prints a human-readable report to the console.
fn print_human_readable_report(report: &JudgeReport) {
  println!(
    "Overall Score: {:.3} / {:.3}\n",
    report.score, report.full_score
  );

  // --- Subtasks Table ---
  let mut subtask_table = Table::new();
  subtask_table.load_preset(UTF8_FULL);
  subtask_table.set_header(vec!["#", "Status", "Score", "Full Score"]);

  for (i, subtask) in report.subtask_results.iter().enumerate() {
    let status_str = get_subtask_status(&subtask.statuses);
    let title_case_status = to_title_case(&status_str);
    let colored_status = colorize_status(&status_str, &title_case_status);

    let full_score = subtask.full_score;
    let obtained_score = subtask.scaled_score;

    let score_str = format!("{:.3}", obtained_score);
    let full_score_str = format!("{:.3}", full_score);

    subtask_table.add_row(vec![
      Cell::new(i + 1),
      colored_status,
      Cell::new(score_str),
      Cell::new(full_score_str),
    ]);
  }
  println!("Subtask Results:");
  println!("{subtask_table}");

  // --- Test Cases Table ---
  let mut test_case_table = Table::new();
  test_case_table.load_preset(UTF8_FULL);
  test_case_table.set_header(vec!["Name", "Status", "Score", "Tick", "Memory"]);

  // Sort test cases by name for consistent output
  let mut sorted_test_cases: Vec<_> = report.test_case_results.iter().collect();
  sorted_test_cases.sort_by_key(|(k, _)| *k);

  for (name, case) in sorted_test_cases {
    let title_case_status = to_title_case(&case.status);
    let colored_status = colorize_status(&case.status, &title_case_status);
    let score_str = format!("{:.3}", case.score);
    let tick_str = format_tick(case.tick);
    let memory_str = format_size(case.memory);

    test_case_table.add_row(vec![
      Cell::new(name),
      colored_status,
      Cell::new(score_str),
      Cell::new(tick_str),
      Cell::new(memory_str),
    ]);
  }
  println!("\nTest Case Details:");
  println!("{test_case_table}");
}

pub fn run(judge_opts: &JudgeOpts) -> Result<()> {
  let src_path_abs = PathBuf::from(&judge_opts.src_path)
    .canonicalize()
    .with_context(|| format!("Failed to find source file: {}", judge_opts.src_path))?;

  let problem = load_ad_hoc_problem_spec(&judge_opts.problem, &src_path_abs)?;
  let ad_hoc_name = "__hullAdHoc".to_string();

  let workspace = RuntimeWorkspace::new(std::env::temp_dir().join("hull-judge-runtime"))?;
  let progress = interactive::create_problem_progress(&problem.name);
  let runtime = analyze_problem(
    &problem,
    &workspace,
    RuntimeOptions::new(None).with_progress(progress),
  )?;
  let solution = runtime
    .solutions
    .get(&ad_hoc_name)
    .context("Ad-hoc judged solution was not produced by runtime analysis")?;
  let report = JudgeReport {
    score: solution.score,
    full_score: problem.full_score,
    subtask_results: solution
      .subtask_results
      .iter()
      .zip(problem.subtasks.iter())
      .map(|(result, subtask)| SubtaskResult {
        full_score: subtask.full_score,
        scaled_score: result.scaled_score,
        statuses: result.statuses.clone(),
      })
      .collect(),
    test_case_results: solution
      .test_case_results
      .iter()
      .map(|(name, result)| {
        (
          name.clone(),
          TestCaseResult {
            status: result.status.clone(),
            score: result.score,
            tick: result.tick,
            memory: result.memory,
          },
        )
      })
      .collect(),
  };

  if judge_opts.json {
    println!("{}", serde_json::to_string(&report)?);
  } else {
    print_human_readable_report(&report);
  }

  Ok(())
}
