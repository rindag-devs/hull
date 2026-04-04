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

use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Parser;

use crate::cmd::report::{
  JudgeCliReport, JudgeCliSubtaskResult, JudgeCliTestCaseResult, print_human_readable_report,
};
use crate::interactive;
use crate::runtime::{RuntimeOptions, RuntimeWorkspace, analyze_problem, load_ad_hoc_problem_spec};

#[derive(Parser)]
pub struct JudgeOpts {
  /// Path to the source file to judge.
  pub src_path: String,

  /// Problem name that provides the judging context, e.g. `aPlusB`.
  #[arg(long, short, default_value = "default")]
  pub problem: String,

  /// Number of parallel jobs to use during runtime analysis.
  #[arg(short = 'j', long = "jobs")]
  pub jobs: Option<usize>,

  /// Print the report as JSON instead of a table.
  #[arg(long)]
  pub json: bool,
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
    RuntimeOptions::new(judge_opts.jobs)
      .with_progress(progress)
      .with_solution_names([ad_hoc_name.clone()]),
  )?;
  let solution = runtime
    .solutions
    .get(&ad_hoc_name)
    .context("Ad-hoc judged solution was not produced by runtime analysis")?;
  let report = JudgeCliReport {
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
  };

  if judge_opts.json {
    println!("{}", serde_json::to_string(&report)?);
  } else {
    print_human_readable_report(&report);
  }

  Ok(())
}
