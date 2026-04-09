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
use crate::runtime::analysis::{
  aggregate_subtask_results, run_generate_outputs, run_judge, run_prepare_solution, run_validator,
};
use crate::runtime::bundle_judge::{
  OFFICIAL_DATA_TAR_NAME, copy_submission_source, load_official_data, make_runtime_problem,
  missing_language_error, pack_official_data_tar,
};
use crate::runtime::metadata::load_bundle_judge_problem_spec;
use crate::runtime::types::{
  BundleJudgeProblemSpec, JudgeReport, PreparedSolutionSpec, ProblemSpec, SolutionSpec,
  TestCaseSpec,
};
use crate::runtime::workspace::RuntimeWorkspace;

/// Runs the `uojCustom` compatibility judger inside a packaged UOJ problem.
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
  pub uoj_data_path: String,

  #[arg(long, default_value_t = false)]
  pub round_top_level_score: bool,

  #[arg(long)]
  pub threads: usize,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UojCustomLanguageConfig {
  uoj_to_hull_language_map: HashMap<String, Option<String>>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum TestCaseState {
  Pending,
  Running,
  Done,
}

#[derive(Clone, Debug)]
struct SubtaskSchedule {
  test_case_names: Vec<String>,
  scoring_method: String,
  next_index: usize,
  skipped: bool,
}

#[derive(Clone, Debug)]
struct SchedulerState {
  test_case_states: BTreeMap<String, TestCaseState>,
  subtask_schedules: Vec<SubtaskSchedule>,
}

struct JudgeProgressTracker {
  result_path: PathBuf,
  completed: usize,
  running: usize,
  total: usize,
}

#[derive(Clone, Debug)]
struct TestCaseMaterial {
  name: String,
  input_path: PathBuf,
  official_data_tar_path: PathBuf,
  tick_limit: u64,
  memory_limit: u64,
  groups: Vec<String>,
  trait_hints: BTreeMap<String, bool>,
}

#[derive(Clone, Debug)]
struct ProblemConf {
  n_ex_tests: usize,
  input_pre: String,
  input_suf: String,
  output_pre: String,
  output_suf: String,
}

#[derive(Clone, Debug, Default)]
struct TrivialTestSummary {
  count: usize,
  score: f64,
  max_tick: u64,
  max_memory: u64,
}

type TestCaseTraitsMap = BTreeMap<String, BTreeMap<String, bool>>;

/// Executes one UOJ judging request using Hull's `uojCustom` runtime.
pub fn run(opts: &UojCustomJudgeOpts) -> Result<()> {
  let result = run_impl(opts);
  if let Err(err) = &result {
    let message = format!("{err:#}");
    let _ = write_internal_error_result(Path::new(&opts.uoj_result_path), &message);
  }
  result
}

fn run_impl(opts: &UojCustomJudgeOpts) -> Result<()> {
  let bundle_root = PathBuf::from(&opts.bundle_root);
  let result_path = PathBuf::from(&opts.uoj_result_path);
  let uoj_work_path = PathBuf::from(&opts.uoj_work_path);
  let uoj_data_path = PathBuf::from(&opts.uoj_data_path);
  let problem = load_bundle_judge_problem_spec(&bundle_root, &opts.metadata_path)?;
  let language_config = load_language_config(&bundle_root)?;

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
        &missing_language_error(&opts.submission_language, "UOJ").to_string(),
      );
    }
  };

  let workspace = RuntimeWorkspace::new(std::env::temp_dir().join(format!(
    "hull-uoj-custom-judge-{}-{}",
    problem.name,
    std::process::id()
  )))?;
  let mut progress = JudgeProgressTracker::new(result_path.clone(), 0);

  let participant_source = copy_submission_source(
    &workspace,
    &problem.name,
    Path::new(&opts.submission_file),
    &hull_language,
  )?;

  let runtime_problem =
    make_runtime_problem(&bundle_root, &problem, &participant_source, "uojCustom");
  let main_correct_solution = runtime_problem
    .solutions
    .iter()
    .find(|solution| solution.main_correct_solution)
    .cloned()
    .with_context(|| {
      format!(
        "Problem `{}` is missing main correct solution metadata",
        problem.name
      )
    })?;
  let participant_solution = runtime_problem
    .solutions
    .iter()
    .find(|solution| solution.name == "uojCustom")
    .cloned()
    .context("uojCustom runtime problem must contain participant solution `uojCustom`")?;

  progress.write_message("Compiling submission")?;
  let prepared_solution =
    match run_prepare_solution(&runtime_problem, &participant_solution, &workspace) {
      Ok(solution) => solution,
      Err(err) => {
        return write_compile_error_result(&result_path, &format_prepare_solution_error(&err));
      }
    };

  let is_hack_mode = uoj_work_path.join("hack_input.txt").is_file();
  if is_hack_mode {
    let std_prepared_solution =
      run_prepare_solution(&runtime_problem, &main_correct_solution, &workspace)
        .context("Failed to prepare main correct solution for hack evaluation")?;
    return run_hack_mode(HackModeContext {
      opts,
      problem: &problem,
      runtime_problem: &runtime_problem,
      workspace: &workspace,
      participant_solution: &participant_solution,
      prepared_solution: &prepared_solution,
      main_correct_solution: &main_correct_solution,
      std_prepared_solution: &std_prepared_solution,
    });
  }

  let custom_test_input_path = uoj_work_path.join("input.txt");
  if custom_test_input_path.is_file() {
    let std_prepared_solution =
      run_prepare_solution(&runtime_problem, &main_correct_solution, &workspace)
        .context("Failed to prepare main correct solution for custom test")?;
    return run_custom_test_mode(CustomTestContext {
      problem: &problem,
      runtime_problem: &runtime_problem,
      workspace: &workspace,
      participant_solution: &participant_solution,
      prepared_solution: &prepared_solution,
      main_correct_solution: &main_correct_solution,
      std_prepared_solution: &std_prepared_solution,
      result_path: &result_path,
      input_path: &custom_test_input_path,
    });
  }

  let test_cases = load_normal_test_cases(&bundle_root, &uoj_data_path, &problem)?;
  let runtime_traits = collect_runtime_traits(&test_cases);
  progress = JudgeProgressTracker::new(result_path.clone(), test_cases.len());

  progress.write_test_progress()?;

  let test_case_reports = execute_unique_test_cases(
    &workspace,
    &test_cases,
    &runtime_problem,
    &participant_solution,
    &prepared_solution,
    opts.threads,
    &mut progress,
  )?;

  write_result(
    &result_path,
    &problem,
    &test_cases,
    &runtime_traits,
    &test_case_reports,
    opts.round_top_level_score,
  )
}

/// Writes a `Judgment Failed` style UOJ result file for an internal `uojCustom`
/// failure so the user can see the error without reading judge logs.
fn write_internal_error_result(result_path: &Path, message: &str) -> Result<()> {
  let escaped = xml_escape(message);
  fs::create_dir_all(result_path).with_context(|| {
    format!(
      "Failed to create UOJ result directory for internal error {}",
      result_path.display()
    )
  })?;
  fs::write(result_path.join("cur_status.txt"), "Judgment failed")
    .with_context(|| format!("Failed to write status file into {}", result_path.display()))?;
  fs::write(
    result_path.join("result.txt"),
    format!(
      "error Judgment Failed\ndetails\n<error>{}</error>\n",
      escaped
    ),
  )
  .with_context(|| {
    format!(
      "Failed to write internal error result to {}",
      result_path.display()
    )
  })
}

fn format_prepare_solution_error(err: &anyhow::Error) -> String {
  let message = err.to_string();
  let Some(stderr_marker) = message.find("\nStderr:\n") else {
    return message;
  };
  let stderr = &message[(stderr_marker + "\nStderr:\n".len())..];
  if !stderr.trim().is_empty() {
    return stderr.trim().to_string();
  }
  let Some(stdout_marker) = message.find("\nStdout:\n") else {
    return message;
  };
  let stdout = &message[(stdout_marker + "\nStdout:\n".len())..stderr_marker];
  if !stdout.trim().is_empty() {
    return stdout.trim().to_string();
  }
  message
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

fn execute_unique_test_cases(
  workspace: &RuntimeWorkspace,
  test_cases: &[TestCaseMaterial],
  runtime_problem: &ProblemSpec,
  participant_solution: &SolutionSpec,
  prepared_solution: &PreparedSolutionSpec,
  threads: usize,
  progress: &mut JudgeProgressTracker,
) -> Result<BTreeMap<String, JudgeReport>> {
  let mut reports = BTreeMap::new();
  let thread_count = if threads > 0 {
    threads
  } else {
    default_parallelism()
  };
  let thread_pool = build_uoj_custom_thread_pool(thread_count)?;

  let runtime_traits = collect_runtime_traits(test_cases);
  let mut scheduler = SchedulerState::new(test_cases, &runtime_problem.subtasks, &runtime_traits);

  while !scheduler.is_finished() {
    let ready_test_case_names = scheduler.collect_ready_test_case_names(thread_count);
    if ready_test_case_names.is_empty() {
      scheduler.mark_irrelevant_pending_test_cases_done();
      if scheduler.is_finished() {
        break;
      }
      return Err(anyhow!(
        "uojCustom scheduler reached a dead end with unfinished active subtasks"
      ));
    }

    scheduler.mark_running(&ready_test_case_names);
    progress.completed = scheduler.completed_count();
    progress.running = ready_test_case_names.len();
    progress.write_test_progress()?;

    let executions = evaluate_test_case_batch(
      workspace,
      test_cases,
      runtime_problem,
      participant_solution,
      prepared_solution,
      &ready_test_case_names,
      thread_pool.as_ref(),
    )?;

    scheduler.finish_batch(&ready_test_case_names, &executions);
    for (test_case_name, report) in executions {
      reports.insert(test_case_name, report);
    }

    scheduler.mark_irrelevant_pending_test_cases_done();
    progress.completed = scheduler.completed_count();
    progress.running = 0;
    progress.write_test_progress()?;
  }

  Ok(reports)
}

impl JudgeProgressTracker {
  fn new(result_path: PathBuf, total: usize) -> Self {
    Self {
      result_path,
      completed: 0,
      running: 0,
      total,
    }
  }

  fn write_message(&self, status: &str) -> Result<()> {
    fs::write(
      self.result_path.join("cur_status.txt"),
      format!("{status}\n"),
    )
    .with_context(|| {
      format!(
        "Failed to write judging progress to {}",
        self.result_path.display()
      )
    })
  }

  fn write_test_progress(&self) -> Result<()> {
    let remaining = self
      .total
      .saturating_sub(self.completed.saturating_add(self.running));
    self.write_message(&format!(
      "Judging tests: completed {}, running {}, remaining {}",
      self.completed, self.running, remaining
    ))
  }
}

impl SchedulerState {
  fn new(
    test_cases: &[TestCaseMaterial],
    subtasks: &[crate::runtime::types::SubtaskSpec],
    runtime_traits: &TestCaseTraitsMap,
  ) -> Self {
    let test_case_states = test_cases
      .iter()
      .map(|test_case| (test_case.name.clone(), TestCaseState::Pending))
      .collect::<BTreeMap<_, _>>();
    let subtask_schedules = subtasks
      .iter()
      .map(|subtask| SubtaskSchedule {
        test_case_names: test_cases
          .iter()
          .filter(|test_case| {
            test_case_matches_traits(&test_case.name, &subtask.traits, runtime_traits)
          })
          .map(|test_case| test_case.name.clone())
          .collect(),
        scoring_method: subtask.scoring_method.clone(),
        next_index: 0,
        skipped: false,
      })
      .collect();
    Self {
      test_case_states,
      subtask_schedules,
    }
  }

  fn is_finished(&self) -> bool {
    self
      .subtask_schedules
      .iter()
      .all(|schedule| schedule.skipped || schedule.next_index >= schedule.test_case_names.len())
  }

  fn completed_count(&self) -> usize {
    self
      .test_case_states
      .values()
      .filter(|state| **state == TestCaseState::Done)
      .count()
  }

  fn collect_ready_test_case_names(&self, limit: usize) -> Vec<String> {
    if limit == 0 {
      return Vec::new();
    }

    let mut ready = Vec::new();
    let mut seen = BTreeSet::new();

    let mut scan_indices = self
      .subtask_schedules
      .iter()
      .map(|schedule| schedule.next_index)
      .collect::<Vec<_>>();

    while ready.len() < limit {
      let mut made_progress = false;

      for (subtask_index, schedule) in self.subtask_schedules.iter().enumerate() {
        if schedule.skipped {
          continue;
        }

        while scan_indices[subtask_index] < schedule.test_case_names.len() {
          let test_case_name = &schedule.test_case_names[scan_indices[subtask_index]];
          scan_indices[subtask_index] += 1;

          let Some(state) = self.test_case_states.get(test_case_name) else {
            continue;
          };
          if *state != TestCaseState::Pending {
            continue;
          }

          if seen.insert(test_case_name.clone()) {
            ready.push(test_case_name.clone());
          }
          made_progress = true;
          break;
        }

        if ready.len() >= limit {
          break;
        }
      }

      if !made_progress {
        break;
      }
    }

    ready
  }

  fn mark_running(&mut self, test_case_names: &[String]) {
    for test_case_name in test_case_names {
      self
        .test_case_states
        .insert(test_case_name.clone(), TestCaseState::Running);
    }
  }

  fn finish_batch(
    &mut self,
    scheduled_test_case_names: &[String],
    executions: &BTreeMap<String, JudgeReport>,
  ) {
    for test_case_name in scheduled_test_case_names {
      self
        .test_case_states
        .insert(test_case_name.clone(), TestCaseState::Done);
    }

    for schedule in &mut self.subtask_schedules {
      if schedule.skipped {
        continue;
      }
      while let Some(test_case_name) = schedule.current_test_case_name().cloned() {
        let Some(state) = self.test_case_states.get(&test_case_name) else {
          break;
        };
        if *state != TestCaseState::Done {
          break;
        }
        schedule.next_index += 1;
        if schedule.scoring_method == "min"
          && executions
            .get(&test_case_name)
            .is_some_and(|report| report.score <= 0.0)
        {
          schedule.skipped = true;
          break;
        }
      }
    }
  }

  fn mark_irrelevant_pending_test_cases_done(&mut self) {
    let active_test_case_names = self
      .subtask_schedules
      .iter()
      .filter(|schedule| !schedule.skipped)
      .flat_map(|schedule| schedule.test_case_names.iter().skip(schedule.next_index))
      .cloned()
      .collect::<BTreeSet<_>>();

    for (test_case_name, state) in &mut self.test_case_states {
      if *state == TestCaseState::Pending && !active_test_case_names.contains(test_case_name) {
        *state = TestCaseState::Done;
      }
    }
  }
}

impl SubtaskSchedule {
  fn current_test_case_name(&self) -> Option<&String> {
    self.test_case_names.get(self.next_index)
  }
}

fn evaluate_test_case_batch(
  workspace: &RuntimeWorkspace,
  test_cases: &[TestCaseMaterial],
  runtime_problem: &ProblemSpec,
  participant_solution: &SolutionSpec,
  prepared_solution: &PreparedSolutionSpec,
  test_case_names: &[String],
  thread_pool: Option<&ThreadPool>,
) -> Result<BTreeMap<String, JudgeReport>> {
  let test_cases = test_case_names
    .iter()
    .map(|test_case_name| {
      test_cases
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
          workspace,
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
  workspace: &RuntimeWorkspace,
  runtime_problem: &ProblemSpec,
  participant_solution: &SolutionSpec,
  prepared_solution: &PreparedSolutionSpec,
  test_case: &TestCaseMaterial,
) -> Result<JudgeReport> {
  let local_case_dir = workspace.root().join("uoj-data").join(&test_case.name);
  fs::create_dir_all(&local_case_dir)?;

  let input_path = local_case_dir.join("input");
  fs::copy(&test_case.input_path, &input_path).with_context(|| {
    format!(
      "Failed to copy testcase input {} to {}",
      test_case.input_path.display(),
      input_path.display()
    )
  })?;

  let official_outputs_dir = local_case_dir.join("outputs");
  let loaded = load_official_data(
    &test_case.official_data_tar_path,
    Some(&official_outputs_dir),
  )?;

  let runtime_test_case = TestCaseSpec {
    name: loaded.execution_name,
    input_file: Some(input_path.to_string_lossy().into_owned()),
    tick_limit: test_case.tick_limit,
    memory_limit: test_case.memory_limit,
    groups: test_case.groups.clone(),
    trait_hints: loaded.validation.traits,
    generator: None,
    arguments: None,
  };

  run_judge(
    runtime_problem,
    &runtime_test_case,
    &participant_solution.name,
    prepared_solution,
    &official_outputs_dir,
    workspace,
  )
}

fn write_compile_error_result(result_path: &Path, message: &str) -> Result<()> {
  let escaped = xml_escape(message);
  fs::create_dir_all(result_path).with_context(|| {
    format!(
      "Failed to create UOJ result directory for compile error {}",
      result_path.display()
    )
  })?;
  fs::write(result_path.join("cur_status.txt"), "Compile Error").with_context(|| {
    format!(
      "Failed to write compile status into {}",
      result_path.display()
    )
  })?;
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

fn write_result(
  result_path: &Path,
  problem: &BundleJudgeProblemSpec,
  test_cases: &[TestCaseMaterial],
  runtime_traits: &TestCaseTraitsMap,
  test_case_reports: &BTreeMap<String, JudgeReport>,
  round_top_level_score: bool,
) -> Result<()> {
  let traits = runtime_traits;
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
        name: test_case.name.clone(),
        input_file: None,
        tick_limit: test_case.tick_limit,
        memory_limit: test_case.memory_limit,
        groups: test_case.groups.clone(),
        trait_hints: runtime_traits
          .get(&test_case.name)
          .cloned()
          .unwrap_or_default(),
        generator: None,
        arguments: None,
      })
      .collect(),
    subtasks: problem.subtasks.clone(),
    solutions: Vec::new(),
    checker_tests: Vec::new(),
    validator_tests: Vec::new(),
  };
  let subtask_reports = aggregate_subtask_results(&scoring_problem, test_case_reports, traits);

  let mut total_score = 0.0;
  let mut max_memory = 0u64;
  let mut details = String::new();
  details.push_str("<tests>");
  let mut emitted_test_index = 0usize;

  for (index, subtask) in problem.subtasks.iter().enumerate() {
    let matching: Vec<_> = test_cases
      .iter()
      .filter(|test_case| {
        test_case_matches_traits(&test_case.name, &subtask.traits, runtime_traits)
      })
      .map(|test_case| test_case.name.clone())
      .collect();

    let raw_subtask_score = subtask_reports[index].raw_score;
    let scaled_subtask_score = subtask_reports[index].scaled_score * 100.0;
    total_score += scaled_subtask_score;

    details.push_str(&format!(
      "<subtask num=\"{}\" score=\"{}\" info=\"{}\">",
      index,
      scaled_subtask_score,
      subtask_status(&subtask_reports[index].statuses, raw_subtask_score)
    ));

    let should_skip_remaining = subtask.scoring_method == "min" && raw_subtask_score <= 0.0;
    let mut skip_rest = false;
    let trivial_summary = summarize_trivial_test_cases(subtask, &matching, test_case_reports);

    if trivial_summary.count > 1 {
      let num = compact_uoj_extra_test_num(emitted_test_index);
      emitted_test_index += 1;
      details.push_str(&format!(
          "<test num=\"{}\" score=\"{}\" info=\"Accepted\" time=\"{}\" memory=\"{}\"><res>{} trivial test cases</res></test>",
          num,
          trivial_summary.score,
          trivial_summary.max_tick,
          trivial_summary.max_memory,
          trivial_summary.count
        ));
    }

    for test_case_name in &matching {
      if skip_rest {
        continue;
      }

      let Some(report) = test_case_reports.get(test_case_name) else {
        let num = compact_uoj_extra_test_num(emitted_test_index);
        emitted_test_index += 1;
        details.push_str(&format!(
          "<test num=\"{}\" score=\"0\" info=\"Skipped\" time=\"0\" memory=\"0\"/>",
          num
        ));
        continue;
      };
      max_memory = max_memory.max(report.memory);

      let point_score = if subtask.scoring_method == "sum" {
        if matching.is_empty() {
          0.0
        } else {
          report.score * subtask.full_score * 100.0 / matching.len() as f64
        }
      } else {
        report.score * subtask.full_score * 100.0
      };

      if trivial_summary.count > 1 && is_trivial_test_case(report) {
        continue;
      }

      let compact_test_num = compact_uoj_extra_test_num(emitted_test_index);
      emitted_test_index += 1;

      details.push_str(&format!(
        "<test num=\"{}\" score=\"{}\" info=\"{}\" time=\"{}\" memory=\"{}\"><res>{}</res></test>",
        compact_test_num,
        point_score,
        to_uoj_info(&report.status),
        report.tick,
        report.memory,
        xml_escape(&report.message),
      ));

      if should_skip_remaining && report.score <= 0.0 {
        skip_rest = true;
      }
    }

    details.push_str("</subtask>");
  }

  details.push_str("</tests>");

  let total_tick = test_case_reports
    .values()
    .map(|report| report.tick)
    .max()
    .unwrap_or(0);
  let top_level_score = if round_top_level_score {
    total_score.round().to_string()
  } else {
    total_score.to_string()
  };

  fs::write(
    result_path.join("result.txt"),
    format!(
      "score {}\ntime {}\nmemory {}\ndetails\n{}",
      top_level_score, total_tick, max_memory, details
    ),
  )
  .with_context(|| format!("Failed to write UOJ result to {}", result_path.display()))
}

fn load_normal_test_cases(
  bundle_root: &Path,
  uoj_data_path: &Path,
  problem: &BundleJudgeProblemSpec,
) -> Result<Vec<TestCaseMaterial>> {
  let mut test_cases = problem
    .test_cases
    .iter()
    .map(|test_case| {
      let official_data_tar_path = bundle_root
        .join("data")
        .join(&test_case.name)
        .join(OFFICIAL_DATA_TAR_NAME);
      let loaded = load_official_data(&official_data_tar_path, None).with_context(|| {
        format!(
          "Failed to read official data header for bundled testcase {}",
          official_data_tar_path.display()
        )
      })?;
      Ok(TestCaseMaterial {
        name: test_case.name.clone(),
        input_path: bundle_root.join("data").join(&test_case.name).join("input"),
        official_data_tar_path,
        tick_limit: test_case.tick_limit,
        memory_limit: test_case.memory_limit,
        groups: test_case.groups.clone(),
        trait_hints: loaded.validation.traits,
      })
    })
    .collect::<Result<Vec<_>>>()?;

  let problem_conf_path = uoj_data_path.join("problem.conf");
  if !problem_conf_path.is_file() {
    return Ok(test_cases);
  }
  let problem_conf = load_problem_conf(&problem_conf_path)?;
  for ex_index in 1..=problem_conf.n_ex_tests {
    let input_path = uoj_data_path.join(format!(
      "ex_{}{}.{}",
      problem_conf.input_pre, ex_index, problem_conf.input_suf
    ));
    let official_data_tar_path = uoj_data_path.join(format!(
      "ex_{}{}.{}",
      problem_conf.output_pre, ex_index, problem_conf.output_suf
    ));
    if !input_path.is_file() || !official_data_tar_path.is_file() {
      continue;
    }
    let loaded = load_official_data(&official_data_tar_path, None).with_context(|| {
      format!(
        "Failed to read official data header for extra test {}",
        official_data_tar_path.display()
      )
    })?;
    test_cases.push(TestCaseMaterial {
      name: format!("ex{ex_index}"),
      input_path,
      official_data_tar_path,
      tick_limit: problem.tick_limit,
      memory_limit: problem.memory_limit,
      groups: Vec::new(),
      trait_hints: loaded.validation.traits,
    });
  }

  Ok(test_cases)
}

fn collect_runtime_traits(test_cases: &[TestCaseMaterial]) -> TestCaseTraitsMap {
  test_cases
    .iter()
    .map(|test_case| (test_case.name.clone(), test_case.trait_hints.clone()))
    .collect()
}

fn load_problem_conf(problem_conf_path: &Path) -> Result<ProblemConf> {
  let content = fs::read_to_string(problem_conf_path).with_context(|| {
    format!(
      "Failed to read UOJ problem.conf {}",
      problem_conf_path.display()
    )
  })?;
  let mut entries = BTreeMap::new();
  for line in content.lines() {
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed.starts_with('#') {
      continue;
    }
    let mut parts = trimmed.split_whitespace();
    let Some(key) = parts.next() else {
      continue;
    };
    entries.insert(key.to_string(), parts.collect::<Vec<_>>().join(" "));
  }
  Ok(ProblemConf {
    n_ex_tests: entries
      .get("n_ex_tests")
      .context("problem.conf is missing n_ex_tests")?
      .parse::<usize>()
      .context("Failed to parse n_ex_tests in problem.conf")?,
    input_pre: entries
      .get("input_pre")
      .cloned()
      .context("problem.conf is missing input_pre")?,
    input_suf: entries
      .get("input_suf")
      .cloned()
      .context("problem.conf is missing input_suf")?,
    output_pre: entries
      .get("output_pre")
      .cloned()
      .context("problem.conf is missing output_pre")?,
    output_suf: entries
      .get("output_suf")
      .cloned()
      .context("problem.conf is missing output_suf")?,
  })
}

struct HackModeContext<'a> {
  opts: &'a UojCustomJudgeOpts,
  problem: &'a BundleJudgeProblemSpec,
  runtime_problem: &'a ProblemSpec,
  workspace: &'a RuntimeWorkspace,
  participant_solution: &'a SolutionSpec,
  prepared_solution: &'a PreparedSolutionSpec,
  main_correct_solution: &'a SolutionSpec,
  std_prepared_solution: &'a PreparedSolutionSpec,
}

struct CustomTestContext<'a> {
  problem: &'a BundleJudgeProblemSpec,
  runtime_problem: &'a ProblemSpec,
  workspace: &'a RuntimeWorkspace,
  participant_solution: &'a SolutionSpec,
  prepared_solution: &'a PreparedSolutionSpec,
  main_correct_solution: &'a SolutionSpec,
  std_prepared_solution: &'a PreparedSolutionSpec,
  result_path: &'a Path,
  input_path: &'a Path,
}

fn run_custom_test_mode(ctx: CustomTestContext<'_>) -> Result<()> {
  let validation = run_validator(ctx.runtime_problem, ctx.input_path, 1)
    .context("Failed to validate custom test input")?;
  if validation.status != "valid" {
    return write_custom_test_result(
      ctx.result_path,
      0.0,
      "Wrong Answer",
      &validation.message,
      0,
      0,
      None,
    );
  }

  let custom_test_case = TestCaseSpec {
    name: "custom-test".to_string(),
    input_file: Some(ctx.input_path.to_string_lossy().into_owned()),
    tick_limit: ctx.problem.tick_limit,
    memory_limit: ctx.problem.memory_limit,
    groups: Vec::new(),
    trait_hints: validation.traits,
    generator: None,
    arguments: None,
  };

  let official_outputs_dir = run_generate_outputs(
    ctx.runtime_problem,
    &custom_test_case,
    &ctx.main_correct_solution.name,
    ctx.std_prepared_solution,
    ctx.workspace,
  )
  .context("Failed to generate official outputs for custom test")?;
  let report = run_judge(
    ctx.runtime_problem,
    &custom_test_case,
    &ctx.participant_solution.name,
    ctx.prepared_solution,
    &official_outputs_dir,
    ctx.workspace,
  )?;
  write_custom_test_result(
    ctx.result_path,
    report.score * 100.0,
    &to_uoj_custom_test_info(&report.status),
    &report.message,
    report.tick,
    report.memory,
    Some(Path::new(&report.outputs)),
  )
}

fn run_hack_mode(ctx: HackModeContext<'_>) -> Result<()> {
  let work_path = Path::new(&ctx.opts.uoj_work_path);
  let result_path = Path::new(&ctx.opts.uoj_result_path);
  let hack_input_path = work_path.join("hack_input.txt");
  let official_data_tar_path = result_path.join("std_output.txt");
  let hack_test_case = TestCaseSpec {
    name: "hack".to_string(),
    input_file: Some(hack_input_path.to_string_lossy().into_owned()),
    tick_limit: ctx.problem.tick_limit,
    memory_limit: ctx.problem.memory_limit,
    groups: Vec::new(),
    trait_hints: BTreeMap::new(),
    generator: None,
    arguments: None,
  };

  let validation = run_validator(ctx.runtime_problem, &hack_input_path, 1)
    .context("Failed to validate hack input")?;
  if validation.status != "valid" {
    write_hack_input_invalid_result(result_path, &validation.message)?;
    return Ok(());
  }
  let std_test_case = TestCaseSpec {
    trait_hints: validation.traits.clone(),
    ..hack_test_case.clone()
  };
  let official_outputs_dir = run_generate_outputs(
    ctx.runtime_problem,
    &std_test_case,
    &ctx.main_correct_solution.name,
    ctx.std_prepared_solution,
    ctx.workspace,
  )
  .context("Failed to generate official outputs for hack input")?;
  pack_official_data_tar(
    &std_test_case.name,
    &validation,
    &official_outputs_dir,
    &official_data_tar_path,
  )?;

  let report = run_judge(
    ctx.runtime_problem,
    &std_test_case,
    &ctx.participant_solution.name,
    ctx.prepared_solution,
    &official_outputs_dir,
    ctx.workspace,
  )?;
  write_hack_result(result_path, &report)
}

fn write_hack_input_invalid_result(result_path: &Path, message: &str) -> Result<()> {
  let escaped = xml_escape(message);
  fs::write(result_path.join("cur_status.txt"), "Invalid hack input").with_context(|| {
    format!(
      "Failed to write invalid hack status into {}",
      result_path.display()
    )
  })?;
  fs::write(
    result_path.join("result.txt"),
    format!(
      "score 0\ntime 0\nmemory 0\ndetails\n<tests><test num=\"1\" score=\"0\" info=\"Invalid Input\" time=\"0\" memory=\"0\"><res>{}</res></test></tests>",
      escaped
    ),
  )
  .with_context(|| {
    format!(
      "Failed to write invalid hack input result to {}",
      result_path.display()
    )
  })
}

fn write_hack_result(result_path: &Path, report: &JudgeReport) -> Result<()> {
  let hack_succeeded = report.score < 1.0;
  let point_score = if hack_succeeded { 0.0 } else { 100.0 };
  let message = xml_escape(&report.message);
  let test_xml = format!(
    "<test num=\"1\" score=\"{}\" info=\"{}\" time=\"{}\" memory=\"{}\"><res>{}</res></test>",
    point_score,
    to_uoj_info(&report.status),
    report.tick,
    report.memory,
    message,
  );

  fs::write(
    result_path.join("result.txt"),
    format!(
      "score {}\ntime {}\nmemory {}\ndetails\n<tests>{}</tests>",
      if hack_succeeded { "1" } else { "0" },
      report.tick,
      report.memory,
      test_xml,
    ),
  )
  .with_context(|| {
    format!(
      "Failed to write UOJ hack result to {}",
      result_path.display()
    )
  })
}

fn write_custom_test_result(
  result_path: &Path,
  score: f64,
  info: &str,
  message: &str,
  tick: u64,
  memory: u64,
  outputs_dir: Option<&Path>,
) -> Result<()> {
  let output_blocks = outputs_dir
    .map(custom_test_output_blocks)
    .transpose()?
    .unwrap_or_default();
  let details = format!(
    "<tests><test num=\"0\" score=\"{}\" info=\"{}\" time=\"{}\" memory=\"{}\">{}<res>{}</res></test></tests>",
    score,
    xml_escape(info),
    tick,
    memory,
    output_blocks,
    xml_escape(message),
  );

  fs::write(result_path.join("cur_status.txt"), format!("{info}\n")).with_context(|| {
    format!(
      "Failed to write custom test status into {}",
      result_path.display()
    )
  })?;
  fs::write(
    result_path.join("result.txt"),
    format!(
      "score 0\ntime {}\nmemory {}\ndetails\n{}",
      tick, memory, details
    ),
  )
  .with_context(|| {
    format!(
      "Failed to write custom test result to {}",
      result_path.display()
    )
  })
}

fn to_uoj_custom_test_info(status: &str) -> String {
  match status {
    "accepted" => "Success".to_string(),
    _ => to_uoj_info(status),
  }
}

fn custom_test_output_blocks(outputs_dir: &Path) -> Result<String> {
  let mut outputs = Vec::new();
  collect_custom_test_outputs(outputs_dir, outputs_dir, &mut outputs)?;
  let preview_limit = custom_test_output_preview_limit(outputs.len());
  Ok(
    outputs
      .into_iter()
      .map(|(name, content)| {
        let preview = truncate_custom_test_output(&content, preview_limit);
        format!(
          "<h4>output: {}</h4><pre>{}</pre>",
          xml_escape(&name),
          xml_escape(&preview)
        )
      })
      .collect(),
  )
}

fn collect_custom_test_outputs(
  root_dir: &Path,
  current_dir: &Path,
  outputs: &mut Vec<(String, Vec<u8>)>,
) -> Result<()> {
  let mut entries = fs::read_dir(current_dir)
    .with_context(|| format!("Failed to read outputs directory {}", current_dir.display()))?
    .collect::<Result<Vec<_>, _>>()?;
  entries.sort_by_key(|entry| entry.file_name());

  for entry in entries {
    let path = entry.path();
    let file_type = entry.file_type()?;
    if file_type.is_dir() {
      collect_custom_test_outputs(root_dir, &path, outputs)?;
      continue;
    }
    if !file_type.is_file() {
      continue;
    }
    let relative = path
      .strip_prefix(root_dir)
      .with_context(|| format!("Failed to relativize output path {}", path.display()))?;
    let content = fs::read(&path).unwrap_or_else(|_| b"<binary output>".to_vec());
    outputs.push((relative.to_string_lossy().into_owned(), content));
  }

  Ok(())
}

fn custom_test_output_preview_limit(outputs_count: usize) -> usize {
  const CUSTOM_TEST_OUTPUT_TOTAL_PREVIEW_LIMIT: usize = 12 * 1024;

  if outputs_count == 0 {
    return CUSTOM_TEST_OUTPUT_TOTAL_PREVIEW_LIMIT;
  }

  CUSTOM_TEST_OUTPUT_TOTAL_PREVIEW_LIMIT / outputs_count
}

fn truncate_custom_test_output(content: &[u8], preview_limit: usize) -> String {
  if content.len() <= preview_limit {
    return String::from_utf8_lossy(content).into_owned();
  }

  let omitted = content.len() - preview_limit;
  let preview = String::from_utf8_lossy(&content[..preview_limit]).into_owned();
  format!("{}\n[{} bytes omitted]", preview, omitted)
}

fn summarize_trivial_test_cases(
  subtask: &crate::runtime::types::SubtaskSpec,
  matching_test_case_names: &[String],
  test_case_reports: &BTreeMap<String, JudgeReport>,
) -> TrivialTestSummary {
  let mut summary = TrivialTestSummary::default();
  for test_case_name in matching_test_case_names {
    let Some(report) = test_case_reports.get(test_case_name) else {
      continue;
    };
    if !is_trivial_test_case(report) {
      continue;
    }
    summary.count += 1;
    if subtask.scoring_method == "sum" {
      summary.score += report.score * subtask.full_score;
    };
    summary.max_tick = summary.max_tick.max(report.tick);
    summary.max_memory = summary.max_memory.max(report.memory);
  }
  if subtask.scoring_method == "sum" {
    summary.score = summary.score * 100.0 / matching_test_case_names.len() as f64;
  } else {
    summary.score = 1.0;
  }
  summary
}

fn is_trivial_test_case(report: &JudgeReport) -> bool {
  report.score >= 1.0 && report.status == "accepted" && report.message.is_empty()
}

fn test_case_matches_traits(
  test_case_name: &str,
  required_traits: &BTreeMap<String, bool>,
  runtime_traits: &TestCaseTraitsMap,
) -> bool {
  required_traits.iter().all(|(name, value)| {
    runtime_traits
      .get(test_case_name)
      .and_then(|traits| traits.get(name))
      == Some(value)
  })
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
    "partially_correct" => "Acceptable Answer",
    "runtime_error" => "Runtime Error",
    "time_limit_exceeded" => "Time Limit Exceeded",
    "memory_limit_exceeded" => "Memory Limit Exceeded",
    _ => "Judgment Failed",
  }
  .to_string()
}

fn compact_uoj_extra_test_num(mut index: usize) -> String {
  const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
  let base = ALPHABET.len();
  let mut encoded = Vec::new();

  loop {
    encoded.push(ALPHABET[index % base] as char);
    if index < base {
      break;
    }
    index = index / base - 1;
  }

  encoded.iter().rev().collect()
}

fn xml_escape(text: &str) -> String {
  text
    .replace('&', "&amp;")
    .replace('<', "&lt;")
    .replace('>', "&gt;")
    .replace('"', "&quot;")
    .replace('\'', "&apos;")
}

#[cfg(test)]
mod tests {
  use super::*;
  use crate::runtime::bundle_judge::build_runtime_solutions;
  use crate::runtime::types::BundleJudgeProblemSpec;
  use std::fs;

  #[test]
  fn keeps_participant_solution_distinct() {
    let problem: BundleJudgeProblemSpec = serde_json::from_str(
      r#"{
        "name": "aplusb",
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
        "subtasks": [],
        "solutions": [
          {
            "name": "std",
            "src": "solutions/std.cpp",
            "mainCorrectSolution": true,
            "participantVisibility": false
          }
        ],
        "testCases": []
      }"#,
    )
    .expect("valid bundled problem spec");

    let runtime_solutions = build_runtime_solutions(
      Path::new("/bundle-root"),
      &problem,
      "/tmp/submission.c.89.s64m",
      "uojCustom",
    );

    assert_eq!(runtime_solutions[0].name, "std");
    assert_eq!(runtime_solutions[1].name, "uojCustom");

    let participant_solution = runtime_solutions
      .iter()
      .find(|solution| solution.name == "uojCustom")
      .expect("participant solution should exist");
    assert_eq!(participant_solution.src, "/tmp/submission.c.89.s64m");
    assert!(!participant_solution.main_correct_solution);
  }

  #[test]
  fn formats_prepare_solution_error() {
    let err = anyhow!(
      "prepareSolution `/runner` failed.\nStdout:\n\nStderr:\nclass A{{}}; is invalid in C89"
    );
    assert_eq!(
      format_prepare_solution_error(&err),
      "class A{}; is invalid in C89"
    );
  }

  #[test]
  fn writes_compile_error_result() {
    let workspace = RuntimeWorkspace::new(std::env::temp_dir().join(format!(
      "hull-uoj-custom-test-{}-{}",
      std::process::id(),
      "compile-error"
    )))
    .expect("create workspace");
    let result_path = workspace.root().join("result");

    write_compile_error_result(&result_path, "compile failed").expect("write compile result");

    assert_eq!(
      fs::read_to_string(result_path.join("cur_status.txt")).expect("read cur status"),
      "Compile Error"
    );
    assert_eq!(
      fs::read_to_string(result_path.join("result.txt")).expect("read result"),
      "error Compile Error\ndetails\n<error>compile failed</error>\n"
    );
  }

  #[test]
  fn writes_custom_test() {
    let workspace = RuntimeWorkspace::new(std::env::temp_dir().join(format!(
      "hull-uoj-custom-test-{}-{}",
      std::process::id(),
      "custom-test"
    )))
    .expect("create workspace");
    let result_path = workspace.root().join("result");
    fs::create_dir_all(&result_path).expect("create result dir");

    write_custom_test_result(&result_path, 100.0, "Success", "", 12, 34, None)
      .expect("write custom test result");

    assert_eq!(
      fs::read_to_string(result_path.join("result.txt")).expect("read result"),
      "score 0\ntime 12\nmemory 34\ndetails\n<tests><test num=\"0\" score=\"100\" info=\"Success\" time=\"12\" memory=\"34\"><res></res></test></tests>"
    );
  }

  #[test]
  fn writes_custom_test_outputs() {
    let workspace = RuntimeWorkspace::new(std::env::temp_dir().join(format!(
      "hull-uoj-custom-test-{}-{}",
      std::process::id(),
      "custom-test-outputs"
    )))
    .expect("create workspace");
    let result_path = workspace.root().join("result");
    let outputs_path = workspace.root().join("outputs");
    fs::create_dir_all(outputs_path.join("nested")).expect("create outputs dir");
    fs::create_dir_all(&result_path).expect("create result dir");
    fs::write(outputs_path.join("first"), "hello").expect("write first output");
    fs::write(outputs_path.join("nested/second"), "world").expect("write second output");

    write_custom_test_result(
      &result_path,
      100.0,
      "Success",
      "",
      12,
      34,
      Some(&outputs_path),
    )
    .expect("write custom test result");

    assert_eq!(
      fs::read_to_string(result_path.join("result.txt")).expect("read result"),
      "score 0\ntime 12\nmemory 34\ndetails\n<tests><test num=\"0\" score=\"100\" info=\"Success\" time=\"12\" memory=\"34\"><h4>output: first</h4><pre>hello</pre><h4>output: nested/second</h4><pre>world</pre><res></res></test></tests>"
    );
  }

  #[test]
  fn scales_output_budget() {
    assert_eq!(custom_test_output_preview_limit(1), 12 * 1024);
    assert_eq!(custom_test_output_preview_limit(2), 6 * 1024);
    assert_eq!(custom_test_output_preview_limit(3), 4 * 1024);
  }

  #[test]
  fn truncates_output_preview() {
    assert_eq!(
      truncate_custom_test_output(b"abcdef", 3),
      "abc\n[3 bytes omitted]"
    );
  }

  #[test]
  fn maps_custom_test_info() {
    assert_eq!(to_uoj_custom_test_info("accepted"), "Success");
    assert_eq!(
      to_uoj_custom_test_info("partially_correct"),
      "Acceptable Answer"
    );
  }
}
