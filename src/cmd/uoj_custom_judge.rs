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
use std::ffi::OsStr;
use std::fs;
use std::io::Cursor;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow};
use base64::Engine;
use clap::Parser;
use rayon::{ThreadPool, ThreadPoolBuilder, prelude::*};
use serde::Deserialize;
use tar::{Archive, Builder, Header};

use crate::platform::default_parallelism;
use crate::runtime::analysis::{
  aggregate_subtask_results, run_generate_outputs, run_judge, run_prepare_solution, run_validator,
};
use crate::runtime::metadata::load_bundle_judge_problem_spec;
use crate::runtime::types::{
  BundleJudgeProblemSpec, JudgeReport, PreparedSolutionSpec, ProblemSpec, SolutionSpec,
  TestCaseSpec, ValidationReport,
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
  traits: BTreeMap<String, bool>,
}

#[derive(Clone, Debug)]
struct LoadedOfficialData {
  execution_name: String,
  validation: ValidationReport,
}

#[derive(Clone, Debug, Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct OfficialDataMetadata {
  test_case_name: String,
}

#[derive(Clone, Debug)]
struct ProblemConf {
  n_ex_tests: usize,
  input_pre: String,
  input_suf: String,
  output_pre: String,
  output_suf: String,
}

type TestCaseTraitsMap = BTreeMap<String, BTreeMap<String, bool>>;

const OFFICIAL_DATA_TAR_NAME: &str = "official-data.tar";
const OFFICIAL_DATA_TEXT_PREFIX: &str = "HULL_OFFICIAL_DATA_TAR_BASE64_V1\n";

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
        &unsupported_language_compile_error(&opts.submission_language).to_string(),
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

  let runtime_problem = make_runtime_problem(&bundle_root, &problem, &participant_source);
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
    .first()
    .cloned()
    .context("uojCustom runtime problem must contain one solution")?;

  progress.write_message("Compiling submission")?;
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

  let is_hack_mode = uoj_work_path.join("hack_input.txt").is_file();
  if is_hack_mode {
    let std_prepared_solution =
      run_prepare_solution(&runtime_problem, &main_correct_solution, &workspace)
        .context("Failed to prepare main correct solution for hack evaluation")?;
    return run_hack_mode(
      opts,
      &problem,
      &runtime_problem,
      &workspace,
      &participant_solution,
      &prepared_solution,
      &main_correct_solution,
      &std_prepared_solution,
    );
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
    opts.ticks_per_ms,
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
  bundle_root: &Path,
  problem: &BundleJudgeProblemSpec,
  participant_source: &str,
) -> ProblemSpec {
  ProblemSpec {
    name: problem.name.clone(),
    tick_limit: problem.tick_limit,
    memory_limit: problem.memory_limit,
    full_score: problem.full_score,
    checker: problem.checker.clone(),
    validator: problem.validator.clone(),
    generators: BTreeMap::new(),
    main_correct_solution: problem.main_correct_solution.clone(),
    judger: problem.judger.clone(),
    test_cases: Vec::new(),
    subtasks: problem.subtasks.clone(),
    solutions: problem
      .solutions
      .iter()
      .map(|solution| {
        if solution.main_correct_solution {
          SolutionSpec {
            src: if Path::new(&solution.src).is_absolute() {
              solution.src.clone()
            } else {
              bundle_root
                .join(&solution.src)
                .to_string_lossy()
                .into_owned()
            },
            ..solution.clone()
          }
        } else {
          SolutionSpec {
            name: "uojCustom".to_string(),
            src: participant_source.to_string(),
            main_correct_solution: false,
            participant_visibility: true,
          }
        }
      })
      .collect(),
    checker_tests: Vec::new(),
    validator_tests: Vec::new(),
  }
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
    traits: loaded.validation.traits,
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
  ticks_per_ms: f64,
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
        traits: runtime_traits
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
  let mut details = String::with_capacity(test_cases.len().saturating_mul(160));
  details.push_str("<tests>");
  let mut seen_test_cases = BTreeSet::new();
  let mut emitted_test_index = 0usize;

  for (index, subtask) in problem.subtasks.iter().enumerate() {
    let matching = matching_test_case_names(test_cases, &subtask.traits, traits);
    let matching_count = matching.len();
    let raw_subtask_score = subtask_reports[index].raw_score;
    let scaled_subtask_score = subtask_reports[index].scaled_score * 100.0;
    total_score += scaled_subtask_score;

    details.push_str(&format!(
      "<subtask num=\"{}\" score=\"{}\" info=\"{}\">",
      index,
      format_score(scaled_subtask_score),
      xml_escape(&subtask_status(
        &subtask_reports[index].statuses,
        raw_subtask_score
      ))
    ));

    let should_skip_remaining = subtask.scoring_method == "min" && raw_subtask_score <= 0.0;
    let mut skip_rest = false;

    for test_case_name in matching {
      if !seen_test_cases.insert(test_case_name.clone()) {
        continue;
      }

      let compact_test_num = compact_uoj_extra_test_num(emitted_test_index);
      emitted_test_index += 1;

      if skip_rest {
        continue;
      }

      let Some(report) = test_case_reports.get(&test_case_name) else {
        details.push_str(&format!(
          "<test num=\"{}\" score=\"0\" info=\"Skipped\" time=\"0\" memory=\"0\"/>",
          compact_test_num
        ));
        continue;
      };
      max_memory = max_memory.max(report.memory);

      let point_score = if subtask.scoring_method == "sum" {
        if matching_count == 0 {
          0.0
        } else {
          report.score * subtask.full_score * 100.0 / matching_count as f64
        }
      } else {
        report.score * subtask.full_score * 100.0
      };

      let message = xml_escape(&report.message);
      if message.is_empty() {
        details.push_str(&format!(
          "<test num=\"{}\" score=\"{}\" info=\"{}\" time=\"{}\" memory=\"{}\"><res/></test>",
          compact_test_num,
          format_score(point_score),
          xml_escape(&to_uoj_info(&report.status)),
          tick_to_ms(report.tick, ticks_per_ms),
          bytes_to_uoj_kb(report.memory)
        ));
      } else {
        details.push_str(&format!(
          "<test num=\"{}\" score=\"{}\" info=\"{}\" time=\"{}\" memory=\"{}\"><res>{}</res></test>",
          compact_test_num,
          format_score(point_score),
          xml_escape(&to_uoj_info(&report.status)),
          tick_to_ms(report.tick, ticks_per_ms),
          bytes_to_uoj_kb(report.memory),
          message,
        ));
      }

      if should_skip_remaining && report.score <= 0.0 {
        skip_rest = true;
      }
    }

    details.push_str("</subtask>");
  }

  details.push_str("</tests>");

  let total_time_ms = if ticks_per_ms <= 0.0 {
    0
  } else {
    let max_tick = test_case_reports
      .values()
      .map(|report| report.tick)
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
        traits: loaded.validation.traits,
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
      traits: loaded.validation.traits,
    });
  }

  Ok(test_cases)
}

fn collect_runtime_traits(test_cases: &[TestCaseMaterial]) -> TestCaseTraitsMap {
  test_cases
    .iter()
    .map(|test_case| (test_case.name.clone(), test_case.traits.clone()))
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

fn load_official_data(
  official_data_tar_path: &Path,
  official_outputs_dir: Option<&Path>,
) -> Result<LoadedOfficialData> {
  if let Some(official_outputs_dir) = official_outputs_dir {
    if official_outputs_dir.exists() {
      fs::remove_dir_all(official_outputs_dir).with_context(|| {
        format!(
          "Failed to reset official outputs directory {}",
          official_outputs_dir.display()
        )
      })?;
    }
    fs::create_dir_all(official_outputs_dir)?;
  }

  let tar_bytes = read_official_data_payload(official_data_tar_path)?;
  let mut archive = Archive::new(Cursor::new(tar_bytes));
  let mut metadata = None;
  let mut validation = None;
  for entry in archive
    .entries()
    .context("Failed to iterate official data tar entries")?
  {
    let mut entry = entry?;
    let path = entry.path()?.to_path_buf();
    if path == Path::new("official-data-metadata.json") {
      let mut bytes = Vec::new();
      std::io::Read::read_to_end(&mut entry, &mut bytes)?;
      metadata = Some(
        serde_json::from_slice::<OfficialDataMetadata>(&bytes)
          .context("Failed to parse official-data-metadata.json from official data tar")?,
      );
      continue;
    }
    if path == Path::new("validation.json") {
      let mut bytes = Vec::new();
      std::io::Read::read_to_end(&mut entry, &mut bytes)?;
      validation = Some(
        serde_json::from_slice::<ValidationReport>(&bytes)
          .context("Failed to parse validation.json from official data tar")?,
      );
      continue;
    }
    if let Ok(relative) = path.strip_prefix("outputs") {
      let Some(official_outputs_dir) = official_outputs_dir else {
        continue;
      };
      if relative.as_os_str().is_empty() {
        continue;
      }
      let target_path = official_outputs_dir.join(relative);
      if let Some(parent) = target_path.parent() {
        fs::create_dir_all(parent)?;
      }
      entry.unpack(&target_path).with_context(|| {
        format!(
          "Failed to unpack official output {} to {}",
          path.display(),
          target_path.display()
        )
      })?;
    }
  }

  Ok(LoadedOfficialData {
    execution_name: metadata
      .map(|metadata| metadata.test_case_name)
      .unwrap_or_else(|| "hack".to_string()),
    validation: validation.context("official data tar is missing validation.json")?,
  })
}

fn pack_official_data_tar(
  test_case_name: &str,
  validation: &ValidationReport,
  outputs_dir: &Path,
  target_path: &Path,
) -> Result<()> {
  if let Some(parent) = target_path.parent() {
    fs::create_dir_all(parent)?;
  }
  let mut builder = Builder::new(Vec::new());

  let validation_bytes = serde_json::to_vec(validation)
    .context("Failed to serialize validation report into official data tar")?;
  let metadata_bytes = serde_json::to_vec(&OfficialDataMetadata {
    test_case_name: test_case_name.to_string(),
  })
  .context("Failed to serialize official data metadata into official data tar")?;
  let mut metadata_header = Header::new_gnu();
  metadata_header.set_size(metadata_bytes.len() as u64);
  metadata_header.set_mode(0o644);
  metadata_header.set_cksum();
  builder
    .append_data(
      &mut metadata_header,
      "official-data-metadata.json",
      Cursor::new(metadata_bytes),
    )
    .context("Failed to append official-data-metadata.json to official data tar")?;
  let mut header = Header::new_gnu();
  header.set_size(validation_bytes.len() as u64);
  header.set_mode(0o644);
  header.set_cksum();
  builder
    .append_data(
      &mut header,
      "validation.json",
      Cursor::new(validation_bytes),
    )
    .context("Failed to append validation.json to official data tar")?;
  append_outputs_to_tar(&mut builder, outputs_dir, outputs_dir)?;
  builder
    .finish()
    .context("Failed to finalize official data tar")?;
  let tar_bytes = builder
    .into_inner()
    .context("Failed to extract official data tar bytes")?;
  write_official_data_payload(target_path, &tar_bytes)
}

fn append_outputs_to_tar(
  builder: &mut Builder<Vec<u8>>,
  root_dir: &Path,
  current_dir: &Path,
) -> Result<()> {
  for entry in fs::read_dir(current_dir)
    .with_context(|| format!("Failed to read outputs directory {}", current_dir.display()))?
  {
    let entry = entry?;
    let path = entry.path();
    let file_type = entry.file_type()?;
    if file_type.is_dir() {
      append_outputs_to_tar(builder, root_dir, &path)?;
      continue;
    }
    if !file_type.is_file() {
      continue;
    }
    let relative = path
      .strip_prefix(root_dir)
      .with_context(|| format!("Failed to relativize output path {}", path.display()))?;
    builder
      .append_path_with_name(&path, Path::new("outputs").join(relative))
      .with_context(|| {
        format!(
          "Failed to append output file {} to official data tar",
          path.display()
        )
      })?;
  }
  Ok(())
}

fn read_official_data_payload(official_data_path: &Path) -> Result<Vec<u8>> {
  let payload = fs::read(official_data_path).with_context(|| {
    format!(
      "Failed to read official data payload {}",
      official_data_path.display()
    )
  })?;
  if official_data_path.extension() == Some(OsStr::new("tar")) {
    return Ok(payload);
  }
  let text = String::from_utf8(payload).with_context(|| {
    format!(
      "Official data payload {} is neither tar nor UTF-8 armored text",
      official_data_path.display()
    )
  })?;
  let encoded = text
    .strip_prefix(OFFICIAL_DATA_TEXT_PREFIX)
    .with_context(|| {
      format!(
        "Official data payload {} is missing armored prefix",
        official_data_path.display()
      )
    })?
    .replace('\n', "");
  base64::engine::general_purpose::STANDARD
    .decode(encoded)
    .with_context(|| {
      format!(
        "Failed to decode armored official data {}",
        official_data_path.display()
      )
    })
}

fn write_official_data_payload(target_path: &Path, tar_bytes: &[u8]) -> Result<()> {
  if let Some(parent) = target_path.parent() {
    fs::create_dir_all(parent)?;
  }
  if target_path.extension() == Some(OsStr::new("tar")) {
    return fs::write(target_path, tar_bytes).with_context(|| {
      format!(
        "Failed to write binary official data tar {}",
        target_path.display()
      )
    });
  }
  let encoded = base64::engine::general_purpose::STANDARD.encode(tar_bytes);
  let mut armored = String::with_capacity(OFFICIAL_DATA_TEXT_PREFIX.len() + encoded.len() + 1);
  armored.push_str(OFFICIAL_DATA_TEXT_PREFIX);
  for chunk in encoded.as_bytes().chunks(76) {
    armored.push_str(std::str::from_utf8(chunk).context("Base64 output was not UTF-8")?);
    armored.push('\n');
  }
  fs::write(target_path, armored).with_context(|| {
    format!(
      "Failed to write armored official data payload {}",
      target_path.display()
    )
  })
}

fn run_hack_mode(
  opts: &UojCustomJudgeOpts,
  problem: &BundleJudgeProblemSpec,
  runtime_problem: &ProblemSpec,
  workspace: &RuntimeWorkspace,
  participant_solution: &SolutionSpec,
  prepared_solution: &PreparedSolutionSpec,
  main_correct_solution: &SolutionSpec,
  std_prepared_solution: &PreparedSolutionSpec,
) -> Result<()> {
  let work_path = Path::new(&opts.uoj_work_path);
  let result_path = Path::new(&opts.uoj_result_path);
  let hack_input_path = work_path.join("hack_input.txt");
  let official_data_tar_path = result_path.join("std_output.txt");
  let hack_test_case = TestCaseSpec {
    name: "hack".to_string(),
    input_file: Some(hack_input_path.to_string_lossy().into_owned()),
    tick_limit: problem.tick_limit,
    memory_limit: problem.memory_limit,
    groups: Vec::new(),
    traits: BTreeMap::new(),
    generator: None,
    arguments: None,
  };

  let validation =
    run_validator(runtime_problem, &hack_input_path, 1).context("Failed to validate hack input")?;
  if validation.status != "valid" {
    write_hack_input_invalid_result(result_path, &validation.message)?;
    return Ok(());
  }
  let std_test_case = TestCaseSpec {
    traits: validation.traits.clone(),
    ..hack_test_case.clone()
  };
  let official_outputs_dir = run_generate_outputs(
    runtime_problem,
    &std_test_case,
    &main_correct_solution.name,
    std_prepared_solution,
    workspace,
  )
  .context("Failed to generate official outputs for hack input")?;
  pack_official_data_tar(
    &std_test_case.name,
    &validation,
    &official_outputs_dir,
    &official_data_tar_path,
  )?;

  let report = run_judge(
    runtime_problem,
    &std_test_case,
    &participant_solution.name,
    prepared_solution,
    &official_outputs_dir,
    workspace,
  )?;
  write_hack_result(result_path, &report, opts.ticks_per_ms)
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

fn write_hack_result(result_path: &Path, report: &JudgeReport, ticks_per_ms: f64) -> Result<()> {
  let hack_succeeded = report.score < 1.0;
  let point_score = if hack_succeeded { 0.0 } else { 100.0 };
  let message = xml_escape(&report.message);
  let test_xml = if message.is_empty() {
    format!(
      "<test num=\"1\" score=\"{}\" info=\"{}\" time=\"{}\" memory=\"{}\"><res/></test>",
      format_score(point_score),
      xml_escape(&to_uoj_info(&report.status)),
      tick_to_ms(report.tick, ticks_per_ms),
      bytes_to_uoj_kb(report.memory)
    )
  } else {
    format!(
      "<test num=\"1\" score=\"{}\" info=\"{}\" time=\"{}\" memory=\"{}\"><res>{}</res></test>",
      format_score(point_score),
      xml_escape(&to_uoj_info(&report.status)),
      tick_to_ms(report.tick, ticks_per_ms),
      bytes_to_uoj_kb(report.memory),
      message,
    )
  };

  fs::write(
    result_path.join("result.txt"),
    format!(
      "score {}\ntime {}\nmemory {}\ndetails\n<tests>{}</tests>",
      if hack_succeeded { "1" } else { "0" },
      tick_to_ms(report.tick, ticks_per_ms),
      bytes_to_uoj_kb(report.memory),
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

fn matching_test_case_names(
  test_cases: &[TestCaseMaterial],
  required_traits: &BTreeMap<String, bool>,
  runtime_traits: &TestCaseTraitsMap,
) -> Vec<String> {
  test_cases
    .iter()
    .filter(|test_case| test_case_matches_traits(&test_case.name, required_traits, runtime_traits))
    .map(|test_case| test_case.name.clone())
    .collect()
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
