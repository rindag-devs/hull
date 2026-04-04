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
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use clap::Parser;
use comfy_table::presets::UTF8_FULL_CONDENSED;
use comfy_table::{Cell, Table};
use serde::Serialize;

use crate::cmd::report::{
  JudgeCliReport, JudgeCliSubtaskResult, JudgeCliTestCaseResult, get_subtask_status,
};
use crate::runtime::{
  ProgramSpec, RuntimeWorkspace, SelfEvalJudgeProblemSpec, SelfEvalLanguageSpec, SolutionSpec,
  TestCaseSpec, aggregate_subtask_results, load_selfeval_contest_spec, load_selfeval_problem_spec,
  run_judge, run_prepare_solution,
};
use crate::utils::{format_size, format_tick};

#[derive(Parser)]
pub struct SelfEvalOpts {
  /// Participant root directory containing one subdirectory per problem.
  pub participant_root: String,

  /// Print the report as JSON instead of a table.
  #[arg(long)]
  pub json: bool,

  /// Bundle root directory shipped alongside the `selfeval` launcher.
  #[arg(long, hide = true)]
  pub bundle_root: Option<String>,

  /// Exported participant package root containing bundled sample data.
  #[arg(long, hide = true)]
  pub package_root: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SelfEvalCliReport {
  score: f64,
  full_score: f64,
  problems: Vec<SelfEvalProblemReport>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SelfEvalProblemReport {
  name: String,
  score: f64,
  full_score: f64,
  subtask_results: Vec<JudgeCliSubtaskResult>,
  test_case_results: BTreeMap<String, JudgeCliTestCaseResult>,
}

pub fn run(opts: &SelfEvalOpts) -> Result<()> {
  let participant_root = PathBuf::from(&opts.participant_root)
    .canonicalize()
    .with_context(|| format!("Failed to find participant root {}", opts.participant_root))?;
  let bundle_root = opts
    .bundle_root
    .as_ref()
    .map(PathBuf::from)
    .unwrap_or_else(|| participant_root.join(".."));
  let package_root = opts
    .package_root
    .as_ref()
    .map(PathBuf::from)
    .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| bundle_root.clone()));
  let contest = load_selfeval_contest_spec(&bundle_root)?;

  let mut overall_score = 0.0;
  let overall_full_score = contest
    .problems
    .iter()
    .map(|problem| problem.full_score)
    .sum();
  let mut problem_reports = Vec::new();

  for contest_problem in &contest.problems {
    let problem = load_selfeval_problem_spec(&bundle_root, &contest_problem.metadata_path)?;
    let problem_dir = participant_root.join(&contest_problem.name);
    let source_path =
      find_participant_source(&problem_dir, &contest_problem.name, &contest.languages)?;
    let report = match source_path {
      Some((source_path, hull_language)) => {
        evaluate_problem(&package_root, &problem, &source_path, &hull_language)?
      }
      None => JudgeCliReport {
        score: 0.0,
        full_score: problem.full_score,
        subtask_results: vec![JudgeCliSubtaskResult {
          full_score: problem.full_score,
          scaled_score: 0.0,
          statuses: vec!["internal_error".to_string()],
        }],
        test_case_results: BTreeMap::from([(
          problem.name.clone(),
          JudgeCliTestCaseResult {
            status: "internal_error".to_string(),
            score: 0.0,
            tick: 0,
            memory: 0,
          },
        )])
        .into_iter()
        .collect(),
      },
    };

    overall_score += report.score;
    problem_reports.push(SelfEvalProblemReport {
      name: problem.name.clone(),
      score: report.score,
      full_score: report.full_score,
      subtask_results: report.subtask_results,
      test_case_results: report.test_case_results.into_iter().collect(),
    });
  }

  let overall = SelfEvalCliReport {
    score: overall_score,
    full_score: overall_full_score,
    problems: problem_reports,
  };

  if opts.json {
    println!("{}", serde_json::to_string(&overall)?);
  } else {
    print_selfeval_human_readable_report(&overall);
  }

  Ok(())
}

fn print_selfeval_human_readable_report(report: &SelfEvalCliReport) {
  println!(
    "Overall Score: {:.3} / {:.3}\n",
    report.score, report.full_score
  );

  for problem in &report.problems {
    println!(
      "Problem {}: {:.3} / {:.3}",
      problem.name, problem.score, problem.full_score
    );

    let mut subtask_table = Table::new();
    subtask_table.load_preset(UTF8_FULL_CONDENSED);
    subtask_table.set_header(vec!["#", "Status", "Score", "Full Score"]);
    for (index, subtask) in problem.subtask_results.iter().enumerate() {
      subtask_table.add_row(vec![
        Cell::new(index),
        Cell::new(get_subtask_status(&subtask.statuses)),
        Cell::new(format!("{:.3}", subtask.scaled_score)),
        Cell::new(format!("{:.3}", subtask.full_score)),
      ]);
    }
    println!("Subtasks:");
    println!("{subtask_table}");

    let mut test_case_table = Table::new();
    test_case_table.load_preset(UTF8_FULL_CONDENSED);
    test_case_table.set_header(vec!["Name", "Status", "Score", "Tick", "Memory"]);
    let mut sorted_test_cases: Vec<_> = problem.test_case_results.iter().collect();
    sorted_test_cases.sort_by_key(|(name, _)| *name);
    for (name, case) in sorted_test_cases {
      test_case_table.add_row(vec![
        Cell::new(name),
        Cell::new(&case.status),
        Cell::new(format!("{:.3}", case.score)),
        Cell::new(format_tick(case.tick)),
        Cell::new(format_size(case.memory)),
      ]);
    }
    println!("Test Cases:");
    println!("{test_case_table}\n");
  }
}

fn evaluate_problem(
  package_root: &Path,
  problem: &SelfEvalJudgeProblemSpec,
  source_path: &Path,
  hull_language: &str,
) -> Result<JudgeCliReport> {
  let workspace = RuntimeWorkspace::new(std::env::temp_dir().join(format!(
    "hull-selfeval-{}-{}",
    problem.name,
    std::process::id()
  )))?;

  let local_source_path = workspace.root.join("participant-src").join(format!(
    "{}.{}",
    problem.name,
    hull_language.split('.').rev().collect::<Vec<_>>().join(".")
  ));
  if let Some(parent) = local_source_path.parent() {
    fs::create_dir_all(parent)?;
  }
  fs::copy(source_path, &local_source_path).with_context(|| {
    format!(
      "Failed to copy participant source {} into selfeval workspace",
      source_path.display()
    )
  })?;

  let runtime_problem = crate::runtime::ProblemSpec {
    name: problem.name.clone(),
    tick_limit: problem.tick_limit,
    memory_limit: problem.memory_limit,
    full_score: problem.full_score,
    checker: ProgramSpec {
      src: None,
      wasm: None,
    },
    validator: ProgramSpec {
      src: None,
      wasm: None,
    },
    generators: BTreeMap::new(),
    main_correct_solution: "__unused".to_string(),
    judger: problem.judger.clone(),
    test_cases: Vec::new(),
    subtasks: problem.subtasks.clone(),
    solutions: vec![SolutionSpec {
      name: "selfeval".to_string(),
      src: local_source_path.to_string_lossy().into_owned(),
      main_correct_solution: false,
      participant_visibility: true,
    }],
    checker_tests: Vec::new(),
    validator_tests: Vec::new(),
  };
  let participant_solution = runtime_problem
    .solutions
    .first()
    .cloned()
    .expect("selfeval runtime problem must contain one solution");
  let prepared_solution =
    run_prepare_solution(&runtime_problem, &participant_solution, &workspace)?;

  if problem.test_cases.is_empty() {
    return Ok(JudgeCliReport {
      score: 0.0,
      full_score: problem.full_score,
      subtask_results: problem
        .subtasks
        .iter()
        .map(|subtask| JudgeCliSubtaskResult {
          full_score: subtask.full_score,
          scaled_score: 0.0,
          statuses: Vec::new(),
        })
        .collect(),
      test_case_results: BTreeMap::new().into_iter().collect(),
    });
  }

  let mut test_case_results = BTreeMap::new();
  let mut test_case_traits = BTreeMap::new();

  for test_case in &problem.test_cases {
    let local_case_dir = workspace.root.join("samples").join(&test_case.name);
    fs::create_dir_all(&local_case_dir)?;
    let local_input_path = local_case_dir.join("input");
    fs::copy(
      package_root
        .join(&problem.name)
        .join("data")
        .join(&test_case.name)
        .join("input"),
      &local_input_path,
    )
    .with_context(|| {
      format!(
        "Failed to copy sample input for {}:{}",
        problem.name, test_case.name
      )
    })?;

    let official_outputs_dir = local_case_dir.join("outputs");
    fs::create_dir_all(&official_outputs_dir)?;
    fs::copy(
      package_root
        .join(&problem.name)
        .join("data")
        .join(&test_case.name)
        .join("outputs")
        .join("output"),
      official_outputs_dir.join("output"),
    )
    .with_context(|| {
      format!(
        "Failed to copy sample official output for {}:{}",
        problem.name, test_case.name
      )
    })?;

    let runtime_test_case = TestCaseSpec {
      name: test_case.name.clone(),
      input_file: Some(local_input_path.to_string_lossy().into_owned()),
      tick_limit: test_case.tick_limit,
      memory_limit: test_case.memory_limit,
      groups: test_case.groups.clone(),
      traits: test_case.traits.clone(),
      generator: None,
      arguments: None,
    };
    let report = run_judge(
      &runtime_problem,
      &runtime_test_case,
      &participant_solution.name,
      &prepared_solution,
      &official_outputs_dir,
      &workspace,
    )?;
    test_case_traits.insert(test_case.name.clone(), test_case.traits.clone());
    test_case_results.insert(test_case.name.clone(), report);
  }

  let scoring_problem = crate::runtime::ProblemSpec {
    test_cases: problem
      .test_cases
      .iter()
      .map(|test_case| {
        let local_input_path = workspace
          .root
          .join("samples")
          .join(&test_case.name)
          .join("input");
        TestCaseSpec {
          name: test_case.name.clone(),
          input_file: Some(local_input_path.to_string_lossy().into_owned()),
          tick_limit: test_case.tick_limit,
          memory_limit: test_case.memory_limit,
          groups: test_case.groups.clone(),
          traits: test_case.traits.clone(),
          generator: None,
          arguments: None,
        }
      })
      .collect(),
    ..runtime_problem.clone()
  };
  let subtask_reports =
    aggregate_subtask_results(&scoring_problem, &test_case_results, &test_case_traits);
  let score = subtask_reports
    .iter()
    .map(|report| report.scaled_score)
    .sum();

  Ok(JudgeCliReport {
    score,
    full_score: problem.full_score,
    subtask_results: subtask_reports
      .iter()
      .zip(problem.subtasks.iter())
      .map(|(report, subtask)| JudgeCliSubtaskResult {
        full_score: subtask.full_score,
        scaled_score: report.scaled_score,
        statuses: report.statuses.clone(),
      })
      .collect(),
    test_case_results: test_case_results
      .into_iter()
      .map(|(name, report)| {
        (
          name,
          JudgeCliTestCaseResult {
            status: report.status,
            score: report.score,
            tick: report.tick,
            memory: report.memory,
          },
        )
      })
      .collect(),
  })
}

fn find_participant_source(
  problem_dir: &Path,
  problem_name: &str,
  languages: &[SelfEvalLanguageSpec],
) -> Result<Option<(PathBuf, String)>> {
  if !problem_dir.exists() {
    return Ok(None);
  }

  for language in languages {
    let expected_path = problem_dir.join(format!("{}{}", problem_name, language.file_name_suffix));
    if expected_path.is_file() {
      return Ok(Some((expected_path, language.hull_language.clone())));
    }
  }

  Ok(None)
}
