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

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result, bail};
use rayon::{ThreadPoolBuilder, prelude::*};
use tracing::info;

use super::artifact::realize_artifact;
use super::sandbox::run_wasm_for_stdio;
use super::types::{
  ArtifactSpec, CheckerReport, CheckerRuntimeData, JudgeReport, PreparedSolutionSpec, ProblemSpec,
  RuntimeData, RuntimeOptions, RuntimeSolutionData, RuntimeTestCaseData, RuntimeTestCaseFiles,
  SubtaskRuntimeReport, TestCaseSpec, ValidationReport, ValidatorRuntimeData,
};
use super::workspace::RuntimeWorkspace;
use crate::interactive::{ProblemProgressHandle, TaskHandle, TaskItemReport, TaskKind};
use crate::runner::RunStatus;

const TOOL_TICK_LIMIT: u64 = 10u64.pow(18);
const TOOL_MEMORY_LIMIT: u64 = u32::MAX as u64;

type TestCaseRunMap = BTreeMap<String, (RuntimeTestCaseData, BTreeMap<String, JudgeReport>)>;
type TestCaseTraitsMap = BTreeMap<String, BTreeMap<String, bool>>;

struct JudgerInvocation<'a> {
  runner: &'a ArtifactSpec,
  mode: &'a str,
  input_path: &'a Path,
  test_case: &'a TestCaseSpec,
  solution_name: &'a str,
  prepared_solution: &'a PreparedSolutionSpec,
  outputs_dir: &'a Path,
  judge_context: Option<(&'a Path, &'a Path)>,
  work_dir: &'a Path,
}

struct LiveScoreState {
  per_solution_reports: BTreeMap<String, BTreeMap<String, JudgeReport>>,
  test_case_traits: TestCaseTraitsMap,
}

fn judge_failure_context(problem_name: &str, solution_name: &str, test_case_name: &str) -> String {
  format!(
    "Judge failed for problem `{problem_name}`, solution `{solution_name}`, test case `{test_case_name}`"
  )
}

fn generate_outputs_failure_context(
  problem_name: &str,
  solution_name: &str,
  test_case_name: &str,
) -> String {
  format!(
    "Generate outputs failed for problem `{problem_name}`, solution `{solution_name}`, test case `{test_case_name}`"
  )
}

// Execute the full runtime analysis for one problem and return the data that
// problem and contest targets consume during packaging.
pub fn install_with_pool<T, F>(options: RuntimeOptions, f: F) -> Result<T>
where
  T: Send,
  F: FnOnce() -> Result<T> + Send,
{
  if options.jobs <= 1 {
    return f();
  }

  ThreadPoolBuilder::new()
    .num_threads(options.jobs)
    .build()
    .context("Failed to build rayon thread pool")?
    .install(f)
}

pub fn analyze_problem(
  problem: &ProblemSpec,
  workspace: &RuntimeWorkspace,
  options: RuntimeOptions,
) -> Result<RuntimeData> {
  let progress = options.progress.clone();
  install_with_pool(options, || {
    analyze_problem_in_pool(problem, workspace, Some(&progress))
  })
}

fn analyze_problem_in_pool(
  problem: &ProblemSpec,
  workspace: &RuntimeWorkspace,
  progress: Option<&ProblemProgressHandle>,
) -> Result<RuntimeData> {
  let solutions_by_name: BTreeMap<_, _> = problem
    .solutions
    .iter()
    .map(|solution| (solution.name.clone(), solution.clone()))
    .collect();

  let main_solution = solutions_by_name
    .get(&problem.main_correct_solution)
    .with_context(|| {
      format!(
        "Main correct solution `{}` not found in runtime metadata",
        problem.main_correct_solution
      )
    })?;

  let (validator_test_results, (checker_test_results, test_case_outputs)) = rayon::join(
    || run_validator_tests(problem, workspace, progress),
    || {
      rayon::join(
        || {
          run_checker_tests(
            problem,
            workspace,
            &solutions_by_name,
            main_solution,
            progress,
          )
        },
        || run_test_cases(problem, workspace, progress),
      )
    },
  );

  let validator_test_results = validator_test_results?;
  let checker_test_results = checker_test_results?;
  let test_case_outputs = test_case_outputs?;

  let test_case_runtime = test_case_outputs
    .iter()
    .map(|(test_case_name, (runtime, _))| (test_case_name.clone(), runtime.clone()))
    .collect::<BTreeMap<_, _>>();

  let solution_reports_by_test_case = test_case_outputs
    .into_iter()
    .map(|(test_case_name, (_, reports))| (test_case_name, reports))
    .collect::<BTreeMap<_, _>>();
  let test_case_traits = test_case_runtime
    .iter()
    .map(|(name, test_case)| (name.clone(), test_case.input_validation.traits.clone()))
    .collect::<BTreeMap<_, _>>();

  let solutions_runtime = problem
    .solutions
    .iter()
    .map(|solution| {
      let test_case_results = solution_reports_by_test_case
        .iter()
        .map(|(test_case_name, reports)| {
          let report = reports.get(&solution.name).with_context(|| {
            format!(
              "Missing judge report for solution `{}` on test case `{}`",
              solution.name, test_case_name
            )
          })?;
          Ok((test_case_name.clone(), report.clone()))
        })
        .collect::<Result<BTreeMap<_, _>>>()?;

      let subtask_results =
        aggregate_subtask_results(problem, &test_case_results, &test_case_traits);
      let score = subtask_results
        .iter()
        .map(|result| result.scaled_score)
        .sum();
      Ok((
        solution.name.clone(),
        RuntimeSolutionData {
          test_case_results,
          subtask_results,
          score,
        },
      ))
    })
    .collect::<Result<BTreeMap<_, _>>>()?;

  Ok(RuntimeData {
    checker: CheckerRuntimeData {
      test_inputs: checker_test_results
        .iter()
        .map(|(name, (path, _))| (name.clone(), path.clone()))
        .collect(),
      test_results: checker_test_results
        .into_iter()
        .map(|(name, (_, report))| (name, report))
        .collect(),
    },
    test_cases: test_case_runtime,
    validator: ValidatorRuntimeData {
      test_inputs: validator_test_results
        .iter()
        .map(|(name, (path, _))| (name.clone(), path.clone()))
        .collect(),
      test_results: validator_test_results
        .into_iter()
        .map(|(name, (_, report))| (name, report))
        .collect(),
    },
    solutions: solutions_runtime,
  })
}

fn run_validator_tests(
  problem: &ProblemSpec,
  workspace: &RuntimeWorkspace,
  progress: Option<&ProblemProgressHandle>,
) -> Result<BTreeMap<String, (String, ValidationReport)>> {
  let handle = register_progress_group(
    progress,
    TaskKind::Validator,
    "Validator",
    problem.validator_tests.iter().map(|test| test.name.clone()),
    None,
  );
  problem
    .validator_tests
    .par_iter()
    .map(|test| {
      info!("Running validator test {}", test.name);
      let guard = handle.as_ref().map(|handle| handle.item(test.name.clone()));
      let input_path = resolve_test_input(
        problem,
        workspace,
        test.input_file.as_deref(),
        test.generator.as_deref(),
        test.arguments.as_deref(),
        &format!("validator-test-{}", test.name),
      )?;
      let report = run_validator(problem, &input_path, 1)?;
      if let Some(guard) = guard {
        guard.finish(
          !is_fatal_validation_status(&report.status),
          TaskItemReport {
            status: Some(report.status.clone()),
            ..TaskItemReport::default()
          },
        );
      }
      Ok((
        test.name.clone(),
        (input_path.to_string_lossy().into_owned(), report),
      ))
    })
    .collect()
}

fn run_checker_tests(
  problem: &ProblemSpec,
  workspace: &RuntimeWorkspace,
  solutions_by_name: &BTreeMap<String, super::types::SolutionSpec>,
  main_solution: &super::types::SolutionSpec,
  progress: Option<&ProblemProgressHandle>,
) -> Result<BTreeMap<String, (String, CheckerReport)>> {
  let handle = register_progress_group(
    progress,
    TaskKind::Checker,
    "Checker",
    problem.checker_tests.iter().map(|test| test.name.clone()),
    None,
  );
  problem
    .checker_tests
    .par_iter()
    .map(|test| {
      info!("Running checker test {}", test.name);
      let guard = handle.as_ref().map(|handle| handle.item(test.name.clone()));
      let input_path = resolve_test_input(
        problem,
        workspace,
        test.input_file.as_deref(),
        test.generator.as_deref(),
        test.arguments.as_deref(),
        &format!("checker-test-{}", test.name),
      )?;
      let output_path = match (&test.output_path, &test.output_solution) {
        (Some(path), None) => PathBuf::from(path),
        (None, Some(solution_name)) => {
          let solution = solutions_by_name
            .get(solution_name)
            .with_context(|| format!("Checker test solution `{}` not found", solution_name))?;
          let fake_test_case = TestCaseSpec {
            name: format!("checker-test-{}", test.name),
            input_file: Some(input_path.to_string_lossy().into_owned()),
            tick_limit: problem.tick_limit,
            memory_limit: problem.memory_limit,
            groups: Vec::new(),
            traits: BTreeMap::new(),
            generator: None,
            arguments: None,
          };
          let outputs_dir = run_generate_outputs(
            problem,
            &fake_test_case,
            &solution.name,
            &solution.prepared,
            workspace,
          )?;
          outputs_dir.join(&test.output_name)
        }
        (Some(_), Some(_)) => {
          bail!(
            "Checker test `{}` cannot specify both outputPath and outputSolution",
            test.name
          )
        }
        (None, None) => {
          bail!(
            "Checker test `{}` must specify outputPath or outputSolution",
            test.name
          )
        }
      };

      let fake_answer_case = TestCaseSpec {
        name: format!("checker-answer-{}", test.name),
        input_file: Some(input_path.to_string_lossy().into_owned()),
        tick_limit: problem.tick_limit,
        memory_limit: problem.memory_limit,
        groups: Vec::new(),
        traits: BTreeMap::new(),
        generator: None,
        arguments: None,
      };
      let answer_dir = run_generate_outputs(
        problem,
        &fake_answer_case,
        &main_solution.name,
        &main_solution.prepared,
        workspace,
      )?;
      let report = run_checker(
        problem,
        &input_path,
        &output_path,
        &answer_dir.join(&test.output_name),
      )?;
      if let Some(guard) = guard {
        guard.finish(
          !is_fatal_checker_status(&report.status),
          TaskItemReport {
            status: Some(report.status.clone()),
            score: Some(report.score),
            ..TaskItemReport::default()
          },
        );
      }
      Ok((
        test.name.clone(),
        (input_path.to_string_lossy().into_owned(), report),
      ))
    })
    .collect()
}

fn run_test_cases(
  problem: &ProblemSpec,
  workspace: &RuntimeWorkspace,
  progress: Option<&ProblemProgressHandle>,
) -> Result<TestCaseRunMap> {
  let solutions = &problem.solutions;
  let main_solution = solutions
    .iter()
    .find(|solution| solution.name == problem.main_correct_solution)
    .with_context(|| {
      format!(
        "Main correct solution `{}` not found in runtime metadata",
        problem.main_correct_solution
      )
    })?;

  let solution_handles = if problem.test_cases.is_empty() {
    None
  } else {
    progress.map(|progress| {
      solutions
        .iter()
        .map(|solution| {
          let handle = progress.register_group(
            TaskKind::Solution,
            solution.name.clone(),
            problem
              .test_cases
              .iter()
              .map(|test_case| test_case.name.clone()),
            Some(0.0),
          );
          (solution.name.clone(), handle)
        })
        .collect::<BTreeMap<_, _>>()
    })
  };
  let live_scores = Arc::new(Mutex::new(LiveScoreState {
    per_solution_reports: BTreeMap::new(),
    test_case_traits: BTreeMap::new(),
  }));

  problem
    .test_cases
    .par_iter()
    .map(|test_case| {
      info!("Preparing test case {}", test_case.name);
      let input_path = resolve_test_input(
        problem,
        workspace,
        test_case.input_file.as_deref(),
        test_case.generator.as_deref(),
        test_case.arguments.as_deref(),
        &test_case.name,
      )?;
      let input_path_string = input_path.to_string_lossy().into_owned();
      let trace_level = if test_case.groups.iter().any(|group| group == "sample") {
        2
      } else {
        1
      };
      let validation = run_validator(problem, Path::new(&input_path), trace_level)?;
      let concrete_test_case = TestCaseSpec {
        input_file: Some(input_path_string.clone()),
        ..test_case.clone()
      };
      {
        let mut live_scores = live_scores.lock().unwrap();
        // IMPORTANT: never trust `test_case.traits` from problem metadata here.
        // Those values are author declarations, while subtask membership must be
        // computed from the validator-derived traits we actually observed at
        // runtime. Using the declared traits here would reintroduce the exact
        // regression where empty/mismatched subtasks looked valid in metadata but
        // were wrong during evaluation.
        live_scores
          .test_case_traits
          .insert(test_case.name.clone(), validation.traits.clone());
      }
      let outputs_dir = run_generate_outputs(
        problem,
        &concrete_test_case,
        &main_solution.name,
        &main_solution.prepared,
        workspace,
      )?;
      let outputs_path = outputs_dir.to_string_lossy().into_owned();

      let solution_reports = solutions
        .par_iter()
        .map(|solution| {
          info!("Judging solution {} on {}", solution.name, test_case.name);
          let guard = solution_handles
            .as_ref()
            .and_then(|handles| handles.get(&solution.name))
            .map(|handle| handle.item(test_case.name.clone()));
          let report = run_judge(
            problem,
            &concrete_test_case,
            &solution.name,
            &solution.prepared,
            Path::new(&outputs_path),
            workspace,
          )
          .with_context(|| judge_failure_context(&problem.name, &solution.name, &test_case.name))?;
          if let Some(handle) = solution_handles
            .as_ref()
            .and_then(|handles| handles.get(&solution.name))
          {
            let current_score = {
              let mut live_scores = live_scores.lock().unwrap();
              live_scores
                .per_solution_reports
                .entry(solution.name.clone())
                .or_default()
                .insert(test_case.name.clone(), report.clone());

              aggregate_subtask_results(
                problem,
                live_scores
                  .per_solution_reports
                  .get(&solution.name)
                  .expect("live score reports must exist after insertion"),
                &live_scores.test_case_traits,
              )
              .iter()
              .map(|result| result.scaled_score)
              .sum()
            };
            if let Some(guard) = guard {
              guard.finish(
                !is_fatal_judge_status(&report.status),
                TaskItemReport {
                  status: Some(report.status.clone()),
                  tick: Some(report.tick),
                  memory: Some(report.memory),
                  score: Some(report.score),
                  ..TaskItemReport::default()
                },
              );
            }
            handle.set_score(current_score);
          }
          Ok((solution.name.clone(), report))
        })
        .collect::<Result<BTreeMap<_, _>>>()?;

      Ok((
        test_case.name.clone(),
        (
          RuntimeTestCaseData {
            data: RuntimeTestCaseFiles {
              input: input_path_string,
              outputs: outputs_path,
            },
            input_validation: validation,
          },
          solution_reports,
        ),
      ))
    })
    .collect()
}

fn is_fatal_judge_status(status: &str) -> bool {
  matches!(status, "internal_error")
}

fn is_fatal_validation_status(status: &str) -> bool {
  matches!(status, "internal_error")
}

fn is_fatal_checker_status(status: &str) -> bool {
  matches!(status, "internal_error")
}

fn register_progress_group<I>(
  progress: Option<&ProblemProgressHandle>,
  kind: TaskKind,
  name: &str,
  item_names: I,
  score: Option<f64>,
) -> Option<TaskHandle>
where
  I: IntoIterator<Item = String>,
{
  let item_names = item_names.into_iter().collect::<Vec<_>>();
  if item_names.is_empty() {
    None
  } else {
    progress.map(|progress| progress.register_group(kind, name, item_names, score))
  }
}

fn run_validator(
  problem: &ProblemSpec,
  input_path: &Path,
  reader_trace_level: u8,
) -> Result<ValidationReport> {
  let validator_wasm = realize_artifact(
    problem
      .validator
      .wasm
      .as_ref()
      .context("Validator metadata is missing `wasm`")?,
  )?;

  let result = run_wasm_for_stdio(
    &validator_wasm,
    Some(input_path),
    &[format!("--reader-trace-level={reader_trace_level}")],
    TOOL_TICK_LIMIT,
    TOOL_MEMORY_LIMIT,
    &[],
  )?;

  if result.status != RunStatus::Accepted && result.stderr.is_empty() {
    bail!(
      "Validator runner failed with status {:?}: {}",
      result.status,
      result.error_message
    );
  }

  serde_json::from_slice(&result.stderr).context("Failed to parse validator report JSON")
}

fn run_checker(
  problem: &ProblemSpec,
  input_path: &Path,
  output_path: &Path,
  answer_path: &Path,
) -> Result<CheckerReport> {
  let checker_wasm = realize_artifact(
    problem
      .checker
      .wasm
      .as_ref()
      .context("Checker metadata is missing `wasm`")?,
  )?;

  let mount = vec![
    (input_path.to_path_buf(), "input".to_string()),
    (output_path.to_path_buf(), "output".to_string()),
    (answer_path.to_path_buf(), "answer".to_string()),
  ];

  let result = run_wasm_for_stdio(
    &checker_wasm,
    None,
    &[
      "input".to_string(),
      "output".to_string(),
      "answer".to_string(),
    ],
    TOOL_TICK_LIMIT,
    TOOL_MEMORY_LIMIT,
    &mount,
  )?;

  if result.status != RunStatus::Accepted && result.stderr.is_empty() {
    bail!(
      "Checker runner failed with status {:?}: {}",
      result.status,
      result.error_message
    );
  }

  serde_json::from_slice(&result.stderr).context("Failed to parse checker report JSON")
}

fn run_generate_outputs(
  problem: &ProblemSpec,
  test_case: &TestCaseSpec,
  solution_name: &str,
  prepared_solution: &PreparedSolutionSpec,
  workspace: &RuntimeWorkspace,
) -> Result<PathBuf> {
  let input_path = resolve_test_input(
    problem,
    workspace,
    test_case.input_file.as_deref(),
    test_case.generator.as_deref(),
    test_case.arguments.as_deref(),
    &test_case.name,
  )?;
  let case_dir =
    workspace.case_dir("generate", &format!("{}-{}", test_case.name, solution_name))?;
  let work_dir = workspace.run_dir("generate", &format!("{}-{}", test_case.name, solution_name))?;
  let outputs_dir = case_dir.join("outputs");
  if outputs_dir.exists() {
    fs::remove_dir_all(&outputs_dir).with_context(|| {
      format!(
        "Failed to reset generated outputs directory {}",
        outputs_dir.display()
      )
    })?;
  }
  fs::create_dir_all(&outputs_dir)?;

  run_judger_script(JudgerInvocation {
    runner: &problem.judger.generate_outputs_runner,
    mode: "generateOutputs",
    input_path: &input_path,
    test_case,
    solution_name,
    prepared_solution,
    outputs_dir: &outputs_dir,
    judge_context: None,
    work_dir: &work_dir,
  })
  .with_context(|| {
    generate_outputs_failure_context(&problem.name, solution_name, &test_case.name)
  })?;

  Ok(outputs_dir)
}

fn run_judge(
  problem: &ProblemSpec,
  test_case: &TestCaseSpec,
  solution_name: &str,
  prepared_solution: &PreparedSolutionSpec,
  official_outputs_dir: &Path,
  workspace: &RuntimeWorkspace,
) -> Result<JudgeReport> {
  let input_path = resolve_test_input(
    problem,
    workspace,
    test_case.input_file.as_deref(),
    test_case.generator.as_deref(),
    test_case.arguments.as_deref(),
    &test_case.name,
  )?;
  let case_dir = workspace.case_dir("judge", &format!("{}-{}", solution_name, test_case.name))?;
  let work_dir = workspace.run_dir("judge", &format!("{}-{}", solution_name, test_case.name))?;
  let outputs_dir = case_dir.join("outputs");
  if outputs_dir.exists() {
    fs::remove_dir_all(&outputs_dir).with_context(|| {
      format!(
        "Failed to reset outputs directory {}",
        outputs_dir.display()
      )
    })?;
  }
  fs::create_dir_all(&outputs_dir)?;
  let report_path = case_dir.join("report.json");

  run_judger_script(JudgerInvocation {
    runner: &problem.judger.judge_runner,
    mode: "judge",
    input_path: &input_path,
    test_case,
    solution_name,
    prepared_solution,
    outputs_dir: &outputs_dir,
    judge_context: Some((official_outputs_dir, &report_path)),
    work_dir: &work_dir,
  })
  .with_context(|| judge_failure_context(&problem.name, solution_name, &test_case.name))?;

  let mut report: JudgeReport = serde_json::from_slice(
    &fs::read(&report_path)
      .with_context(|| format!("Failed to read judge report at {}", report_path.display()))?,
  )
  .with_context(|| {
    format!(
      "Failed to parse judge report JSON for problem `{}`, solution `{}`, test case `{}`",
      problem.name, solution_name, test_case.name
    )
  })?;
  report.outputs = outputs_dir.to_string_lossy().into_owned();
  Ok(report)
}

fn run_judger_script(invocation: JudgerInvocation<'_>) -> Result<()> {
  // The packaged runners write helper files into their working directory, so
  // each invocation gets an isolated sandbox directory.
  let runner = realize_runner(invocation.runner)?;
  let mut command = Command::new(&runner);
  command
    .current_dir(invocation.work_dir)
    .env("HULL_MODE", invocation.mode)
    .env("HULL_TESTCASE_NAME", &invocation.test_case.name)
    .env("HULL_SOLUTION_NAME", invocation.solution_name)
    .env("HULL_INPUT_PATH", invocation.input_path)
    .env(
      "HULL_TICK_LIMIT",
      invocation.test_case.tick_limit.to_string(),
    )
    .env(
      "HULL_MEMORY_LIMIT",
      invocation.test_case.memory_limit.to_string(),
    )
    .env("HULL_SOLUTION_SRC", &invocation.prepared_solution.src)
    .env("HULL_OUTPUTS_DIR", invocation.outputs_dir);

  if let Some(executable) = &invocation.prepared_solution.executable {
    command.env("HULL_SOLUTION_EXECUTABLE", realize_artifact(executable)?);
  } else {
    command.env_remove("HULL_SOLUTION_EXECUTABLE");
  }

  match invocation.judge_context {
    Some((official_outputs_dir, report_path)) => {
      command
        .env("HULL_OFFICIAL_OUTPUTS_DIR", official_outputs_dir)
        .env("HULL_REPORT_PATH", report_path);
    }
    None => {
      command.env_remove("HULL_OFFICIAL_OUTPUTS_DIR");
      command.env_remove("HULL_REPORT_PATH");
    }
  }

  let output = command
    .output()
    .with_context(|| format!("Failed to execute judger runner {}", runner))?;
  if !output.status.success() {
    bail!(
      "Judger runner `{}` failed.\nStdout:\n{}\nStderr:\n{}",
      runner,
      String::from_utf8_lossy(&output.stdout).trim(),
      String::from_utf8_lossy(&output.stderr).trim()
    );
  }

  Ok(())
}

fn realize_runner(runner: &ArtifactSpec) -> Result<String> {
  if Path::new(&runner.path).exists() {
    return Ok(runner.path.clone());
  }

  if let Some(drv_path) = &runner.drv_path {
    let output = Command::new("nix")
      .args(["build", "--no-link", &format!("{drv_path}^*")])
      .output()
      .with_context(|| format!("Failed to realize runner {}", runner.path))?;
    if !output.status.success() {
      bail!(
        "Failed to realize runner {}.\nStderr:\n{}",
        runner.path,
        String::from_utf8_lossy(&output.stderr).trim()
      );
    }
  }

  if Path::new(&runner.path).exists() {
    Ok(runner.path.clone())
  } else {
    bail!(
      "Runner path {} does not exist after realization",
      runner.path
    )
  }
}

fn aggregate_subtask_results(
  problem: &ProblemSpec,
  test_case_results: &BTreeMap<String, JudgeReport>,
  test_case_traits: &TestCaseTraitsMap,
) -> Vec<SubtaskRuntimeReport> {
  problem
    .subtasks
    .iter()
    .map(|subtask| {
      let matching_test_case_names = problem
        .test_cases
        .iter()
        .filter(|test_case| {
          subtask.traits.iter().all(|(name, value)| {
            test_case_traits
              .get(&test_case.name)
              .and_then(|traits| traits.get(name))
              == Some(value)
          })
        })
        .map(|test_case| test_case.name.clone())
        .collect::<Vec<_>>();

      let test_cases: BTreeMap<_, _> = matching_test_case_names
        .iter()
        .filter_map(|test_case_name| {
          test_case_results
            .get(test_case_name)
            .cloned()
            .map(|report| (test_case_name.clone(), report))
        })
        .collect();

      let statuses: Vec<String> = BTreeSet::from_iter(
        test_cases
          .values()
          .map(|report| report.status.clone())
          .collect::<Vec<_>>(),
      )
      .into_iter()
      .collect();

      let raw_score = if test_cases.is_empty() {
        0.0
      } else if subtask.scoring_method == "sum" {
        test_cases.values().map(|report| report.score).sum::<f64>() / test_cases.len() as f64
      } else {
        test_cases
          .values()
          .map(|report| report.score)
          .fold(1.0, f64::min)
      };

      SubtaskRuntimeReport {
        test_cases,
        statuses,
        raw_score,
        scaled_score: raw_score * subtask.full_score,
      }
    })
    .collect()
}

fn resolve_test_input(
  problem: &ProblemSpec,
  workspace: &RuntimeWorkspace,
  input_file: Option<&str>,
  generator_name: Option<&str>,
  arguments: Option<&[String]>,
  temp_name: &str,
) -> Result<PathBuf> {
  // Generators and hand-written inputs are normalized into a concrete path so
  // later stages can treat both forms uniformly.
  if let Some(path) = input_file {
    return Ok(PathBuf::from(path));
  }

  let generator_name = generator_name.with_context(|| {
    format!(
      "Input for `{}` is missing both inputFile and generator",
      temp_name
    )
  })?;
  let generator_wasm = problem
    .generators
    .get(generator_name)
    .and_then(|program| program.wasm.as_ref())
    .with_context(|| format!("Generator `{}` is missing `wasm` metadata", generator_name))?;
  let generator_wasm = realize_artifact(generator_wasm)?;
  let result = run_wasm_for_stdio(
    &generator_wasm,
    None,
    arguments.unwrap_or(&[]),
    TOOL_TICK_LIMIT,
    TOOL_MEMORY_LIMIT,
    &[],
  )?;
  let path = workspace
    .case_dir("input", &format!("{}-{temp_name}", problem.name))?
    .join("input.txt");
  fs::write(&path, result.stdout)
    .with_context(|| format!("Failed to write generated input {}", path.display()))?;
  Ok(path)
}

#[cfg(test)]
mod tests {
  use super::*;
  use crate::runtime::{ArtifactSpec, JudgerSpec, ProgramSpec, SubtaskSpec};

  fn judge_report(status: &str, score: f64) -> JudgeReport {
    JudgeReport {
      status: status.to_string(),
      score,
      message: String::new(),
      tick: 0,
      memory: 0,
      outputs: String::new(),
    }
  }

  fn problem_with_subtasks(scoring_method: &str) -> ProblemSpec {
    ProblemSpec {
      name: "p".to_string(),
      tick_limit: 1,
      memory_limit: 1,
      full_score: 1.0,
      checker: ProgramSpec {
        src: None,
        wasm: None,
      },
      validator: ProgramSpec {
        src: None,
        wasm: None,
      },
      generators: BTreeMap::new(),
      main_correct_solution: "std".to_string(),
      judger: JudgerSpec {
        generate_outputs_runner: ArtifactSpec {
          path: String::new(),
          drv_path: None,
        },
        judge_runner: ArtifactSpec {
          path: String::new(),
          drv_path: None,
        },
      },
      test_cases: vec![
        TestCaseSpec {
          name: "a".to_string(),
          input_file: None,
          tick_limit: 1,
          memory_limit: 1,
          groups: Vec::new(),
          traits: BTreeMap::new(),
          generator: None,
          arguments: None,
        },
        TestCaseSpec {
          name: "b".to_string(),
          input_file: None,
          tick_limit: 1,
          memory_limit: 1,
          groups: Vec::new(),
          traits: BTreeMap::new(),
          generator: None,
          arguments: None,
        },
      ],
      subtasks: vec![SubtaskSpec {
        full_score: 0.5,
        scoring_method: scoring_method.to_string(),
        traits: BTreeMap::new(),
      }],
      solutions: Vec::new(),
      checker_tests: Vec::new(),
      validator_tests: Vec::new(),
    }
  }

  #[test]
  fn judge_failure_context_mentions_problem_solution_and_test_case() {
    let message = judge_failure_context("aplusb", "wa", "sample-1");
    assert!(message.contains("problem `aplusb`"));
    assert!(message.contains("solution `wa`"));
    assert!(message.contains("test case `sample-1`"));
  }

  #[test]
  fn generate_outputs_failure_context_mentions_problem_solution_and_test_case() {
    let message = generate_outputs_failure_context("wind", "std", "3");
    assert!(message.contains("problem `wind`"));
    assert!(message.contains("solution `std`"));
    assert!(message.contains("test case `3`"));
  }

  #[test]
  fn fatal_status_helpers_match() {
    assert!(is_fatal_judge_status("internal_error"));
    assert!(!is_fatal_judge_status("memory_limit_exceeded"));
    assert!(is_fatal_validation_status("internal_error"));
    assert!(!is_fatal_validation_status("invalid"));
    assert!(is_fatal_checker_status("internal_error"));
    assert!(!is_fatal_checker_status("wrong_answer"));
  }

  #[test]
  fn subtask_results_use_min_scoring() {
    let problem = problem_with_subtasks("min");
    let reports = BTreeMap::from([
      ("a".to_string(), judge_report("accepted", 1.0)),
      ("b".to_string(), judge_report("wrong_answer", 0.25)),
    ]);
    let traits = BTreeMap::from([
      ("a".to_string(), BTreeMap::new()),
      ("b".to_string(), BTreeMap::new()),
    ]);

    let result = aggregate_subtask_results(&problem, &reports, &traits);
    assert_eq!(result.len(), 1);
    assert!((result[0].raw_score - 0.25).abs() < 1e-9);
    assert!((result[0].scaled_score - 0.125).abs() < 1e-9);
    assert_eq!(result[0].statuses, vec!["accepted", "wrong_answer"]);
  }

  #[test]
  fn subtask_results_use_average_for_sum() {
    let problem = problem_with_subtasks("sum");
    let reports = BTreeMap::from([
      ("a".to_string(), judge_report("accepted", 1.0)),
      ("b".to_string(), judge_report("partially_correct", 0.5)),
    ]);
    let traits = BTreeMap::from([
      ("a".to_string(), BTreeMap::new()),
      ("b".to_string(), BTreeMap::new()),
    ]);

    let result = aggregate_subtask_results(&problem, &reports, &traits);
    assert_eq!(result.len(), 1);
    assert!((result[0].raw_score - 0.75).abs() < 1e-9);
    assert!((result[0].scaled_score - 0.375).abs() < 1e-9);
  }

  #[test]
  fn subtask_results_ignore_missing_cases() {
    let problem = problem_with_subtasks("min");
    let reports = BTreeMap::from([("a".to_string(), judge_report("accepted", 1.0))]);
    let traits = BTreeMap::from([
      ("a".to_string(), BTreeMap::new()),
      ("b".to_string(), BTreeMap::new()),
    ]);

    let result = aggregate_subtask_results(&problem, &reports, &traits);
    assert_eq!(result[0].test_cases.len(), 1);
    assert_eq!(result[0].statuses, vec!["accepted"]);
    assert!((result[0].raw_score - 1.0).abs() < 1e-9);
  }

  #[test]
  fn subtasks_match_trait_subsets() {
    let mut problem = problem_with_subtasks("min");
    problem.subtasks = vec![SubtaskSpec {
      full_score: 1.0,
      scoring_method: "min".to_string(),
      traits: BTreeMap::from([("x".to_string(), true)]),
    }];
    problem.test_cases[0].traits =
      BTreeMap::from([("x".to_string(), true), ("y".to_string(), true)]);
    problem.test_cases[1].traits = BTreeMap::from([("y".to_string(), true)]);

    let reports = BTreeMap::from([
      ("a".to_string(), judge_report("accepted", 1.0)),
      ("b".to_string(), judge_report("wrong_answer", 0.0)),
    ]);
    let traits = BTreeMap::from([
      (
        "a".to_string(),
        BTreeMap::from([("x".to_string(), true), ("y".to_string(), true)]),
      ),
      ("b".to_string(), BTreeMap::from([("y".to_string(), true)])),
    ]);

    let result = aggregate_subtask_results(&problem, &reports, &traits);
    assert_eq!(result[0].test_cases.len(), 1);
    assert!(result[0].test_cases.contains_key("a"));
    assert_eq!(result[0].statuses, vec!["accepted"]);
  }
}
