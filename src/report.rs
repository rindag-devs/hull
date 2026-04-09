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

use std::collections::{BTreeMap, HashMap};

use comfy_table::presets::UTF8_FULL_CONDENSED;
use comfy_table::{Cell, Color, Table};
use serde::Serialize;

use crate::format::{format_size, format_tick, to_title_case};
use crate::runtime::types::{
  JudgeReport, ProblemSpec, RuntimeSolutionData, SubtaskRuntimeReport, SubtaskSpec,
};

#[derive(Serialize, Debug)]
#[serde(rename_all = "snake_case")]
/// Serializable CLI judging summary shared by `judge` and `cnoi-self-eval`.
pub struct JudgeCliReport {
  pub score: f64,
  pub full_score: f64,
  pub subtask_results: Vec<JudgeCliSubtaskResult>,
  pub test_case_results: HashMap<String, JudgeCliTestCaseResult>,
}

#[derive(Clone, Serialize, Debug)]
#[serde(rename_all = "snake_case")]
/// One subtask entry in a CLI judging summary.
pub struct JudgeCliSubtaskResult {
  pub full_score: f64,
  pub scaled_score: f64,
  pub statuses: Vec<String>,
}

#[derive(Clone, Serialize, Debug)]
#[serde(rename_all = "snake_case")]
/// One testcase entry in a CLI judging summary.
pub struct JudgeCliTestCaseResult {
  pub status: String,
  pub score: f64,
  pub tick: u64,
  pub memory: u64,
}

impl JudgeCliReport {
  /// Builds a CLI report from one analyzed runtime solution and the owning problem spec.
  pub fn from_runtime_solution(problem: &ProblemSpec, solution: &RuntimeSolutionData) -> Self {
    Self {
      score: solution.score,
      full_score: problem.full_score,
      subtask_results: solution
        .subtask_results
        .iter()
        .zip(problem.subtasks.iter())
        .map(|(result, subtask)| JudgeCliSubtaskResult {
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
            JudgeCliTestCaseResult {
              status: result.status.clone(),
              score: result.score,
              tick: result.tick,
              memory: result.memory,
            },
          )
        })
        .collect(),
    }
  }

  /// Builds a CLI report from aggregated subtask reports and raw testcase reports.
  pub fn from_subtask_reports(
    full_score: f64,
    problem_subtasks: &[SubtaskSpec],
    subtask_reports: &[SubtaskRuntimeReport],
    test_case_reports: &BTreeMap<String, JudgeReport>,
  ) -> Self {
    Self {
      score: subtask_reports
        .iter()
        .map(|report| report.scaled_score)
        .sum(),
      full_score,
      subtask_results: subtask_reports
        .iter()
        .zip(problem_subtasks.iter())
        .map(|(report, subtask)| JudgeCliSubtaskResult {
          full_score: subtask.full_score,
          scaled_score: report.scaled_score,
          statuses: report.statuses.clone(),
        })
        .collect(),
      test_case_results: test_case_reports
        .iter()
        .map(|(name, report)| {
          (
            name.clone(),
            JudgeCliTestCaseResult {
              status: report.status.clone(),
              score: report.score,
              tick: report.tick,
              memory: report.memory,
            },
          )
        })
        .collect(),
    }
  }

  /// Renders the report using the shared single-problem human-readable format.
  pub fn render_human_readable(&self) -> String {
    let mut output = String::new();
    output.push_str(&format!(
      "Overall Score: {:.3} / {:.3}\n\n",
      self.score, self.full_score
    ));

    let mut subtask_table = Table::new();
    subtask_table.load_preset(UTF8_FULL_CONDENSED);
    subtask_table.set_header(vec!["#", "Status", "Score", "Full Score"]);

    for (index, subtask) in self.subtask_results.iter().enumerate() {
      let status = get_subtask_status(&subtask.statuses);
      let title_case_status = to_title_case(&status);
      subtask_table.add_row(vec![
        Cell::new(index),
        colorize_status(&status, &title_case_status),
        Cell::new(format!("{:.3}", subtask.scaled_score)),
        Cell::new(format!("{:.3}", subtask.full_score)),
      ]);
    }
    output.push_str("Subtask Results:\n");
    output.push_str(&subtask_table.to_string());
    output.push_str("\n\n");

    let mut test_case_table = Table::new();
    test_case_table.load_preset(UTF8_FULL_CONDENSED);
    test_case_table.set_header(vec!["Name", "Status", "Score", "Tick", "Memory"]);

    let mut sorted_test_cases: Vec<_> = self.test_case_results.iter().collect();
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
    output.push_str("Test Case Details:\n");
    output.push_str(&test_case_table.to_string());
    output
  }
}

fn get_subtask_status(statuses: &[String]) -> String {
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
