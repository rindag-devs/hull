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

use comfy_table::presets::UTF8_FULL_CONDENSED;
use comfy_table::{Cell, Color, Table};
use serde::{Deserialize, Serialize};

use crate::utils::{format_size, format_tick, to_title_case};

#[derive(Deserialize, Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct JudgeCliReport {
  pub score: f64,
  pub full_score: f64,
  pub subtask_results: Vec<JudgeCliSubtaskResult>,
  pub test_case_results: HashMap<String, JudgeCliTestCaseResult>,
}

#[derive(Deserialize, Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct JudgeCliSubtaskResult {
  pub full_score: f64,
  pub scaled_score: f64,
  pub statuses: Vec<String>,
}

#[derive(Deserialize, Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct JudgeCliTestCaseResult {
  pub status: String,
  pub score: f64,
  pub tick: u64,
  pub memory: u64,
}

pub fn get_subtask_status(statuses: &[String]) -> String {
  if statuses.is_empty() {
    return "N/A".to_string();
  }
  statuses
    .iter()
    .find(|status| *status != "accepted")
    .cloned()
    .unwrap_or_else(|| "accepted".to_string())
}

fn colorize_status(status: &str, text: &str) -> Cell {
  match status {
    "accepted" => Cell::new(text).fg(Color::Green),
    "wrong_answer" => Cell::new(text).fg(Color::Red),
    "partially_correct" => Cell::new(text).fg(Color::Cyan),
    "runtime_error" => Cell::new(text).fg(Color::Magenta),
    "time_limit_exceeded" | "memory_limit_exceeded" => Cell::new(text).fg(Color::Yellow),
    "internal_error" => Cell::new(text).fg(Color::Grey),
    _ => Cell::new(text),
  }
}

pub fn print_human_readable_report(report: &JudgeCliReport) {
  println!(
    "Overall Score: {:.3} / {:.3}\n",
    report.score, report.full_score
  );

  let mut subtask_table = Table::new();
  subtask_table.load_preset(UTF8_FULL_CONDENSED);
  subtask_table.set_header(vec!["#", "Status", "Score", "Full Score"]);

  for (index, subtask) in report.subtask_results.iter().enumerate() {
    let status = get_subtask_status(&subtask.statuses);
    let title_case_status = to_title_case(&status);
    subtask_table.add_row(vec![
      Cell::new(index),
      colorize_status(&status, &title_case_status),
      Cell::new(format!("{:.3}", subtask.scaled_score)),
      Cell::new(format!("{:.3}", subtask.full_score)),
    ]);
  }
  println!("Subtask Results:");
  println!("{subtask_table}");

  let mut test_case_table = Table::new();
  test_case_table.load_preset(UTF8_FULL_CONDENSED);
  test_case_table.set_header(vec!["Name", "Status", "Score", "Tick", "Memory"]);

  let mut sorted_test_cases: Vec<_> = report.test_case_results.iter().collect();
  sorted_test_cases.sort_by_key(|(name, _)| *name);

  for (name, case) in sorted_test_cases {
    let title_case_status = to_title_case(&case.status);
    test_case_table.add_row(vec![
      Cell::new(name),
      colorize_status(&case.status, &title_case_status),
      Cell::new(format!("{:.3}", case.score)),
      Cell::new(format_tick(case.tick)),
      Cell::new(format_size(case.memory)),
    ]);
  }
  println!("\nTest Case Details:");
  println!("{test_case_table}");
}
