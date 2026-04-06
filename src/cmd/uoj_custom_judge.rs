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

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow};
use clap::Parser;
use rayon::{ThreadPool, ThreadPoolBuilder, prelude::*};
use serde::Deserialize;

use crate::platform::default_parallelism;
use crate::runtime::analysis::{aggregate_subtask_results, run_judge, run_prepare_solution};
use crate::runtime::metadata::load_selfeval_problem_spec;
use crate::runtime::types::{
  JudgeReport, PreparedSolutionSpec, ProblemSpec, ProgramSpec, SelfEvalJudgeProblemSpec,
  SelfEvalJudgeTestCaseSpec, SolutionSpec, TestCaseSpec,
};
use crate::runtime::workspace::RuntimeWorkspace;

#[derive(Parser)]
pub struct UojCustomJudgeOpts {
  #[arg(long)]
  pub bundle_root: String,

  #[arg(long)]
  pub metadata_path: String,

  #[arg(long)]
  pub submission_file: String,

  #[arg(long)]
  pub submission_language: String,

  #[arg(long)]
  pub uoj_work_path: String,

  #[arg(long)]
  pub uoj_result_path: String,

  #[arg(long)]
  pub ticks_per_ms: f64,

  #[arg(long, default_value_t = 0usize)]
  pub threads: usize,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UojCustomLanguageConfig {
  uoj_to_hull_language_map: HashMap<String, Option<String>>,
}

#[derive(Clone)]
struct TestCaseExecution {
  report: JudgeReport,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum TestCaseState {
  Pending,
  Running,
  Done,
}

#[derive(Clone, Debug)]
struct SubtaskExecutionPlan {
  test_case_names: Vec<String>,
  next_index: usize,
  skip_remaining: bool,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UojCustomInputValidation {
  traits: BTreeMap<String, bool>,
}

pub fn run(opts: &UojCustomJudgeOpts) -> Result<()> {
  let bundle_root = PathBuf::from(&opts.bundle_root);
  let result_path = PathBuf::from(&opts.uoj_result_path);

  let problem = load_selfeval_problem_spec(&bundle_root, &opts.metadata_path)?;
  let language_config = load_language_config(&bundle_root)?;
  let runtime_traits = load_runtime_traits(&bundle_root, &problem)?;

  let hull_language = match language_config
    .uoj_to_hull_language_map
    .get(&opts.submission_language)
    .with_context(|| {
      format!(
        "UOJ language `{}` is not configured in uojToHullLanguageMap",
        opts.submission_language
      )
    })?
    .clone()
  {
    Some(language) => language,
    None => {
      return write_compile_error_result(
        &result_path,
        &unsupported_language_compile_error(&opts.submission_language).to_string(),
      );
    }
  };

  let workspace = RuntimeWorkspace::new(std::env::temp_dir().join(format!(
    "hull-uoj-custom-judge-{}-{}",
    problem.name,
    std::process::id()
  )))?;

  let participant_source = copy_submission_source(
    &workspace,
    &problem.name,
    Path::new(&opts.submission_file),
    &hull_language,
  )?;

  let runtime_problem = make_runtime_problem(&problem, &participant_source);
  let participant_solution = runtime_problem
    .solutions
    .first()
    .cloned()
    .context("uojCustom runtime problem must contain one solution")?;

  let prepared_solution =
    match run_prepare_solution(&runtime_problem, &participant_solution, &workspace) {
      Ok(solution) => solution,
      Err(err) => {
        let error = err.to_string();
        if error.contains("Unsupported solution language") {
          return write_compile_error_result(&result_path, &error);
        }
        return Err(err);
      }
    };

  let test_case_reports = execute_unique_test_cases(
    &bundle_root,
    &workspace,
    &problem,
    &runtime_traits,
    &runtime_problem,
    &participant_solution,
    &prepared_solution,
    opts.threads,
  )?;

  write_uoj_result(
    &result_path,
    &problem,
    &runtime_traits,
    &test_case_reports,
    opts.ticks_per_ms,
  )
}

fn load_language_config(bundle_root: &Path) -> Result<UojCustomLanguageConfig> {
  let path = bundle_root.join("uoj-custom-language-config.json");
  let content = fs::read_to_string(&path).with_context(|| {
    format!(
      "Failed to read uoj custom language config {}",
      path.display()
    )
  })?;
  serde_json::from_str(&content).context("Failed to parse uoj custom language config JSON")
}

fn unsupported_language_compile_error(language: &str) -> anyhow::Error {
  anyhow!(
    "UOJ language `{language}` is configured as unsupported for uojCustom because Hull's WASM judger does not support it"
  )
}

fn copy_submission_source(
  workspace: &RuntimeWorkspace,
  problem_name: &str,
  submission_file: &Path,
  hull_language: &str,
) -> Result<String> {
  let extension = hull_language.split('.').rev().collect::<Vec<_>>().join(".");
  let target = workspace
    .root()
    .join("participant-src")
    .join(format!("{problem_name}.{extension}"));
  if let Some(parent) = target.parent() {
    fs::create_dir_all(parent)?;
  }
  fs::copy(submission_file, &target).with_context(|| {
    format!(
      "Failed to copy UOJ submission {} into runtime workspace",
      submission_file.display()
    )
  })?;
  Ok(target.to_string_lossy().into_owned())
}

fn make_runtime_problem(
  problem: &SelfEvalJudgeProblemSpec,
  participant_source: &str,
) -> ProblemSpec {
  ProblemSpec {
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
      name: "uojCustom".to_string(),
      src: participant_source.to_string(),
      main_correct_solution: false,
      participant_visibility: true,
    }],
    checker_tests: Vec::new(),
    validator_tests: Vec::new(),
  }
}

fn execute_unique_test_cases(
  bundle_root: &Path,
  workspace: &RuntimeWorkspace,
  problem: &SelfEvalJudgeProblemSpec,
  runtime_traits: &BTreeMap<String, BTreeMap<String, bool>>,
  runtime_problem: &ProblemSpec,
  participant_solution: &SolutionSpec,
  prepared_solution: &PreparedSolutionSpec,
  threads: usize,
) -> Result<BTreeMap<String, TestCaseExecution>> {
  let mut reports = BTreeMap::new();
  let mut test_case_states = problem
    .test_cases
    .iter()
    .map(|test_case| (test_case.name.clone(), TestCaseState::Pending))
    .collect::<BTreeMap<_, _>>();
  let mut subtask_plans = problem
    .subtasks
    .iter()
    .map(|subtask| SubtaskExecutionPlan {
      test_case_names: problem
        .test_cases
        .iter()
        .filter(|test_case| {
          subtask.traits.iter().all(|(name, value)| {
            runtime_traits
              .get(&test_case.name)
              .and_then(|traits| traits.get(name))
              == Some(value)
          })
        })
        .map(|test_case| test_case.name.clone())
        .collect(),
      next_index: 0,
      skip_remaining: false,
    })
    .collect::<Vec<_>>();
  let thread_count = resolve_thread_count(threads);
  let thread_pool = build_uoj_custom_thread_pool(thread_count)?;

  // Advance all subtasks in lockstep. Each wave only schedules the current
  // frontier testcase of each subtask, which preserves min-subtask skip
  // semantics while still allowing independent frontiers to run in parallel.
  while !subtask_plans.iter().all(subtask_plan_finished) {
    let ready_test_case_names =
      collect_ready_test_case_names(problem, &subtask_plans, &test_case_states, &reports);
    if ready_test_case_names.is_empty() {
      break;
    }

    for test_case_name in &ready_test_case_names {
      test_case_states.insert(test_case_name.clone(), TestCaseState::Running);
    }

    let executions = evaluate_test_case_batch(
      bundle_root,
      workspace,
      problem,
      runtime_traits,
      runtime_problem,
      participant_solution,
      prepared_solution,
      &ready_test_case_names,
      thread_pool.as_ref(),
    )?;

    for (test_case_name, execution) in executions {
      test_case_states.insert(test_case_name.clone(), TestCaseState::Done);
      reports.insert(test_case_name, execution);
    }

    advance_subtask_plans(problem, &mut subtask_plans, &reports);
  }

  Ok(reports)
}

fn resolve_thread_count(threads: usize) -> usize {
  if threads > 0 {
    return threads;
  }
  default_parallelism()
}

fn subtask_plan_finished(subtask_plan: &SubtaskExecutionPlan) -> bool {
  subtask_plan.skip_remaining || subtask_plan.next_index >= subtask_plan.test_case_names.len()
}

fn collect_ready_test_case_names(
  problem: &SelfEvalJudgeProblemSpec,
  subtask_plans: &[SubtaskExecutionPlan],
  test_case_states: &BTreeMap<String, TestCaseState>,
  reports: &BTreeMap<String, TestCaseExecution>,
) -> Vec<String> {
  let mut ready = BTreeSet::new();

  for (subtask_index, subtask_plan) in subtask_plans.iter().enumerate() {
    if subtask_plan_finished(subtask_plan) {
      continue;
    }

    let test_case_name = &subtask_plan.test_case_names[subtask_plan.next_index];
    let Some(state) = test_case_states.get(test_case_name) else {
      continue;
    };

    match state {
      TestCaseState::Pending => {
        ready.insert(test_case_name.clone());
      }
      TestCaseState::Running => {}
      TestCaseState::Done => {
        // This testcase has already been judged once globally. The subtask may
        // still depend on that result, but we must not enqueue it again.
        if let Some(execution) = reports.get(test_case_name) {
          let subtask = &problem.subtasks[subtask_index];
          if subtask.scoring_method == "min" && execution.report.score <= 0.0 {
            continue;
          }
        }
      }
    }
  }

  ready.into_iter().collect()
}

fn advance_subtask_plans(
  problem: &SelfEvalJudgeProblemSpec,
  subtask_plans: &mut [SubtaskExecutionPlan],
  reports: &BTreeMap<String, TestCaseExecution>,
) {
  for (subtask_index, subtask_plan) in subtask_plans.iter_mut().enumerate() {
    if subtask_plan.skip_remaining {
      continue;
    }

    while subtask_plan.next_index < subtask_plan.test_case_names.len() {
      let test_case_name = &subtask_plan.test_case_names[subtask_plan.next_index];
      let Some(execution) = reports.get(test_case_name) else {
        break;
      };

      // Reuse globally cached testcase results when a testcase belongs to
      // multiple subtasks, but only let a zero-score stop the current min
      // subtask instead of accidentally skipping other subtasks.
      subtask_plan.next_index += 1;
      if problem.subtasks[subtask_index].scoring_method == "min" && execution.report.score <= 0.0 {
        subtask_plan.skip_remaining = true;
        break;
      }
    }
  }
}

fn evaluate_test_case_batch(
  bundle_root: &Path,
  workspace: &RuntimeWorkspace,
  problem: &SelfEvalJudgeProblemSpec,
  runtime_traits: &BTreeMap<String, BTreeMap<String, bool>>,
  runtime_problem: &ProblemSpec,
  participant_solution: &SolutionSpec,
  prepared_solution: &PreparedSolutionSpec,
  test_case_names: &[String],
  thread_pool: Option<&ThreadPool>,
) -> Result<BTreeMap<String, TestCaseExecution>> {
  let test_cases = test_case_names
    .iter()
    .map(|test_case_name| {
      problem
        .test_cases
        .iter()
        .find(|test_case| test_case.name == *test_case_name)
        .with_context(|| format!("Missing test case `{test_case_name}` in uojCustom scheduling"))
    })
    .collect::<Result<Vec<_>>>()?;

  let evaluate = || {
    test_cases
      .par_iter()
      .map(|test_case| {
        let execution = evaluate_test_case(
          bundle_root,
          workspace,
          problem,
          runtime_traits,
          runtime_problem,
          participant_solution,
          prepared_solution,
          test_case,
        )?;
        Ok((test_case.name.clone(), execution))
      })
      .collect::<Result<BTreeMap<_, _>>>()
  };

  if test_cases.len() <= 1 {
    return evaluate();
  }

  if let Some(thread_pool) = thread_pool {
    return thread_pool.install(evaluate);
  }

  evaluate()
}

fn build_uoj_custom_thread_pool(thread_count: usize) -> Result<Option<ThreadPool>> {
  if thread_count <= 1 {
    return Ok(None);
  }

  Ok(Some(
    ThreadPoolBuilder::new()
      .num_threads(thread_count)
      .build()
      .context("Failed to build uojCustom thread pool")?,
  ))
}

fn evaluate_test_case(
  bundle_root: &Path,
  workspace: &RuntimeWorkspace,
  problem: &SelfEvalJudgeProblemSpec,
  runtime_traits: &BTreeMap<String, BTreeMap<String, bool>>,
  runtime_problem: &ProblemSpec,
  participant_solution: &SolutionSpec,
  prepared_solution: &PreparedSolutionSpec,
  test_case: &SelfEvalJudgeTestCaseSpec,
) -> Result<TestCaseExecution> {
  let local_case_dir = workspace.root().join("uoj-data").join(&test_case.name);
  fs::create_dir_all(&local_case_dir)?;

  let input_path = local_case_dir.join("input");
  fs::copy(
    bundle_root.join("data").join(&test_case.name).join("input"),
    &input_path,
  )
  .with_context(|| {
    format!(
      "Failed to copy bundled input for {}:{}",
      problem.name, test_case.name
    )
  })?;

  let official_outputs_dir = local_case_dir.join("outputs");
  fs::create_dir_all(&official_outputs_dir)?;
  let bundled_outputs_dir = bundle_root
    .join("data")
    .join(&test_case.name)
    .join("outputs");
  for entry in fs::read_dir(&bundled_outputs_dir).with_context(|| {
    format!(
      "Failed to read bundled outputs directory for {}:{}",
      problem.name, test_case.name
    )
  })? {
    let entry = entry?;
    let file_type = entry.file_type()?;
    if !file_type.is_file() {
      continue;
    }
    fs::copy(entry.path(), official_outputs_dir.join(entry.file_name())).with_context(|| {
      format!(
        "Failed to copy bundled output for {}:{}:{}",
        problem.name,
        test_case.name,
        entry.file_name().to_string_lossy()
      )
    })?;
  }

  let runtime_test_case = TestCaseSpec {
    name: test_case.name.clone(),
    input_file: Some(input_path.to_string_lossy().into_owned()),
    tick_limit: test_case.tick_limit,
    memory_limit: test_case.memory_limit,
    groups: test_case.groups.clone(),
    traits: runtime_traits
      .get(&test_case.name)
      .cloned()
      .unwrap_or_default(),
    generator: None,
    arguments: None,
  };

  let report = run_judge(
    runtime_problem,
    &runtime_test_case,
    &participant_solution.name,
    prepared_solution,
    &official_outputs_dir,
    workspace,
  )?;
  Ok(TestCaseExecution { report })
}

fn write_compile_error_result(result_path: &Path, message: &str) -> Result<()> {
  let escaped = xml_escape(message);
  fs::write(
    result_path.join("result.txt"),
    format!("error Compile Error\ndetails\n<error>{escaped}</error>\n"),
  )
  .with_context(|| {
    format!(
      "Failed to write compile error result to {}",
      result_path.display()
    )
  })
}

fn write_uoj_result(
  result_path: &Path,
  problem: &SelfEvalJudgeProblemSpec,
  runtime_traits: &BTreeMap<String, BTreeMap<String, bool>>,
  test_case_reports: &BTreeMap<String, TestCaseExecution>,
  ticks_per_ms: f64,
) -> Result<()> {
  let traits = runtime_traits;

  let scoring_problem = ProblemSpec {
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
    test_cases: problem
      .test_cases
      .iter()
      .map(|test_case| TestCaseSpec {
        name: test_case.name.clone(),
        input_file: None,
        tick_limit: test_case.tick_limit,
        memory_limit: test_case.memory_limit,
        groups: test_case.groups.clone(),
        traits: test_case.traits.clone(),
        generator: None,
        arguments: None,
      })
      .collect(),
    subtasks: problem.subtasks.clone(),
    solutions: Vec::new(),
    checker_tests: Vec::new(),
    validator_tests: Vec::new(),
  };

  let report_map = test_case_reports
    .iter()
    .map(|(name, execution)| (name.clone(), execution.report.clone()))
    .collect::<BTreeMap<_, _>>();
  let subtask_reports = aggregate_subtask_results(&scoring_problem, &report_map, &traits);

  let mut total_score = 0.0;
  let mut max_memory = 0u64;
  let mut details = String::from("<tests>\n");
  let mut seen_test_cases = BTreeSet::new();

  for (index, subtask) in problem.subtasks.iter().enumerate() {
    let matching = problem
      .test_cases
      .iter()
      .filter(|test_case| {
        subtask
          .traits
          .iter()
          .all(|(name, value)| traits.get(&test_case.name).and_then(|m| m.get(name)) == Some(value))
      })
      .map(|test_case| test_case.name.clone())
      .collect::<Vec<_>>();

    let raw_subtask_score = subtask_reports[index].raw_score;
    let scaled_subtask_score = subtask_reports[index].scaled_score * 100.0;
    total_score += scaled_subtask_score;

    let status = subtask_status(&subtask_reports[index].statuses, raw_subtask_score);
    details.push_str(&format!(
      "<subtask num=\"{}\" score=\"{}\" info=\"{}\">\n",
      index + 1,
      format_score(scaled_subtask_score),
      xml_escape(&status)
    ));

    let should_skip_remaining = subtask.scoring_method == "min" && raw_subtask_score <= 0.0;
    let mut skip_rest = false;

    for test_case_name in matching {
      if !seen_test_cases.insert(test_case_name.clone()) {
        continue;
      }

      if skip_rest {
        continue;
      }

      let Some(execution) = test_case_reports.get(&test_case_name) else {
        details.push_str(&format!(
          "<test num=\"{}\" score=\"0\" info=\"Skipped\" time=\"0\" memory=\"0\">\n<res></res>\n</test>\n",
          xml_escape(&test_case_name)
        ));
        continue;
      };
      max_memory = max_memory.max(execution.report.memory);

      let point_score = if subtask.scoring_method == "sum" {
        let case_count = problem
          .test_cases
          .iter()
          .filter(|test_case| {
            subtask.traits.iter().all(|(name, value)| {
              traits.get(&test_case.name).and_then(|m| m.get(name)) == Some(value)
            })
          })
          .count();
        if case_count == 0 {
          0.0
        } else {
          execution.report.score * subtask.full_score * 100.0 / case_count as f64
        }
      } else {
        execution.report.score * subtask.full_score * 100.0
      };

      details.push_str(&format!(
        "<test num=\"{}\" score=\"{}\" info=\"{}\" time=\"{}\" memory=\"{}\">\n<res>{}</res>\n</test>\n",
        xml_escape(&test_case_name),
        format_score(point_score),
        xml_escape(&to_uoj_info(&execution.report.status)),
        tick_to_ms(execution.report.tick, ticks_per_ms),
        bytes_to_uoj_kb(execution.report.memory),
        xml_escape(&execution.report.message)
      ));

      if should_skip_remaining && execution.report.score <= 0.0 {
        skip_rest = true;
      }
    }

    details.push_str("</subtask>\n");
  }

  details.push_str("</tests>\n");

  let total_time_ms = if ticks_per_ms <= 0.0 {
    0
  } else {
    let max_tick = test_case_reports
      .values()
      .map(|execution| execution.report.tick)
      .max()
      .unwrap_or(0);
    tick_to_ms(max_tick, ticks_per_ms)
  };

  fs::write(
    result_path.join("result.txt"),
    format!(
      "score {}\ntime {}\nmemory {}\ndetails\n{}",
      format_score(total_score),
      total_time_ms,
      bytes_to_uoj_kb(max_memory),
      details
    ),
  )
  .with_context(|| format!("Failed to write UOJ result to {}", result_path.display()))
}

fn load_runtime_traits(
  bundle_root: &Path,
  problem: &SelfEvalJudgeProblemSpec,
) -> Result<BTreeMap<String, BTreeMap<String, bool>>> {
  let mut traits = BTreeMap::new();
  for test_case in &problem.test_cases {
    let validation_path = bundle_root
      .join("data")
      .join(&test_case.name)
      .join("input-validation.json");
    let content = fs::read_to_string(&validation_path).with_context(|| {
      format!(
        "Failed to read bundled input validation for {}:{}",
        problem.name, test_case.name
      )
    })?;
    let validation: UojCustomInputValidation =
      serde_json::from_str(&content).with_context(|| {
        format!(
          "Failed to parse bundled input validation for {}:{}",
          problem.name, test_case.name
        )
      })?;
    traits.insert(test_case.name.clone(), validation.traits);
  }
  Ok(traits)
}

fn subtask_status(statuses: &[String], raw_score: f64) -> String {
  if statuses.is_empty() {
    return "Skipped".to_string();
  }
  if raw_score >= 1.0 {
    return "Accepted".to_string();
  }
  if let Some(status) = statuses.iter().find(|status| status.as_str() != "accepted") {
    return to_uoj_info(status);
  }
  "Accepted".to_string()
}

fn to_uoj_info(status: &str) -> String {
  match status {
    "accepted" => "Accepted",
    "wrong_answer" => "Wrong Answer",
    "partially_correct" => "Partially Correct",
    "runtime_error" => "Runtime Error",
    "time_limit_exceeded" => "Time Limit Exceeded",
    "memory_limit_exceeded" => "Memory Limit Exceeded",
    _ => "Judgment Failed",
  }
  .to_string()
}

fn tick_to_ms(tick: u64, ticks_per_ms: f64) -> u64 {
  if ticks_per_ms <= 0.0 {
    return 0;
  }
  ((tick as f64) / ticks_per_ms).ceil() as u64
}

// UOJ historically spells this field as `kb`, but the stored value is actually
// KiB in the Linux ru_maxrss sense: 1024-byte units, not bits and not SI kB.
fn bytes_to_uoj_kb(bytes: u64) -> u64 {
  bytes.div_ceil(1024)
}

fn format_score(score: f64) -> String {
  if (score.round() - score).abs() < 1e-9 {
    format!("{:.0}", score.round())
  } else {
    format!("{:.6}", score)
  }
}

fn xml_escape(text: &str) -> String {
  text
    .replace('&', "&amp;")
    .replace('<', "&lt;")
    .replace('>', "&gt;")
    .replace('"', "&quot;")
    .replace('\'', "&apos;")
}
