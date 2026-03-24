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
use crate::runner::RunStatus;

const TOOL_TICK_LIMIT: u64 = 10u64.pow(18);
const TOOL_MEMORY_LIMIT: u64 = u32::MAX as u64;

// Execute the full runtime analysis for one problem and return the data that
// problem and contest targets consume during packaging.
pub(crate) fn install_with_pool<T, F>(options: RuntimeOptions, f: F) -> Result<T>
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
  install_with_pool(options, || analyze_problem_in_pool(problem, workspace))
}

pub(crate) fn analyze_problem_in_pool(
  problem: &ProblemSpec,
  workspace: &RuntimeWorkspace,
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
        "Main correct solution '{}' not found in runtime metadata",
        problem.main_correct_solution
      )
    })?;

  let (validator_test_results, (checker_test_results, test_case_outputs)) = rayon::join(
    || run_validator_tests(problem),
    || {
      rayon::join(
        || run_checker_tests(problem, workspace, &solutions_by_name, main_solution),
        || run_test_cases(problem, workspace),
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

  let solutions_runtime = problem
    .solutions
    .iter()
    .map(|solution| {
      let test_case_results = solution_reports_by_test_case
        .iter()
        .map(|(test_case_name, reports)| {
          let report = reports.get(&solution.name).with_context(|| {
            format!(
              "Missing judge report for solution '{}' on test case '{}'",
              solution.name, test_case_name
            )
          })?;
          Ok((test_case_name.clone(), report.clone()))
        })
        .collect::<Result<BTreeMap<_, _>>>()?;

      let subtask_results = aggregate_subtask_results(problem, &test_case_results);
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
) -> Result<BTreeMap<String, (String, ValidationReport)>> {
  problem
    .validator_tests
    .par_iter()
    .map(|test| {
      info!("Running validator test {}", test.name);
      let input_path = resolve_test_input(
        problem,
        test.input_file.as_deref(),
        test.generator.as_deref(),
        test.arguments.as_deref(),
        &format!("validator-test-{}", test.name),
      )?;
      let report = run_validator(problem, &input_path, 1)?;
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
) -> Result<BTreeMap<String, (String, CheckerReport)>> {
  problem
    .checker_tests
    .par_iter()
    .map(|test| {
      info!("Running checker test {}", test.name);
      let input_path = resolve_test_input(
        problem,
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
            .with_context(|| format!("Checker test solution '{}' not found", solution_name))?;
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
          let outputs_dir =
            run_generate_outputs(problem, &fake_test_case, &solution.prepared, workspace)?;
          outputs_dir.join(&test.output_name)
        }
        (Some(_), Some(_)) => {
          bail!(
            "Checker test '{}' cannot specify both outputPath and outputSolution",
            test.name
          )
        }
        (None, None) => {
          bail!(
            "Checker test '{}' must specify outputPath or outputSolution",
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
        &main_solution.prepared,
        workspace,
      )?;
      let report = run_checker(
        problem,
        &input_path,
        &output_path,
        &answer_dir.join(&test.output_name),
      )?;
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
) -> Result<BTreeMap<String, (RuntimeTestCaseData, BTreeMap<String, JudgeReport>)>> {
  let solutions = &problem.solutions;
  let main_solution = solutions
    .iter()
    .find(|solution| solution.name == problem.main_correct_solution)
    .with_context(|| {
      format!(
        "Main correct solution '{}' not found in runtime metadata",
        problem.main_correct_solution
      )
    })?;

  problem
    .test_cases
    .par_iter()
    .map(|test_case| {
      info!("Preparing test case {}", test_case.name);
      let input_path = resolve_test_input(
        problem,
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
      let outputs_dir = run_generate_outputs(
        problem,
        &concrete_test_case,
        &main_solution.prepared,
        workspace,
      )?;
      let outputs_path = outputs_dir.to_string_lossy().into_owned();

      let solution_reports = solutions
        .par_iter()
        .map(|solution| {
          info!("Judging solution {} on {}", solution.name, test_case.name);
          let report = run_judge(
            problem,
            &concrete_test_case,
            &solution.prepared,
            Path::new(&outputs_path),
            workspace,
          )?;
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
  prepared_solution: &PreparedSolutionSpec,
  workspace: &RuntimeWorkspace,
) -> Result<PathBuf> {
  let input_path = resolve_test_input(
    problem,
    test_case.input_file.as_deref(),
    test_case.generator.as_deref(),
    test_case.arguments.as_deref(),
    &test_case.name,
  )?;
  let case_dir = workspace.case_dir(
    "generate",
    &format!("{}-{}", test_case.name, prepared_solution.src),
  )?;
  let work_dir = workspace.run_dir(
    "generate",
    &format!("{}-{}", test_case.name, prepared_solution.src),
  )?;
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

  run_judger_script(
    &problem.judger.generate_outputs_runner,
    "generateOutputs",
    &input_path,
    test_case,
    prepared_solution,
    &outputs_dir,
    None,
    &work_dir,
  )?;

  Ok(outputs_dir)
}

fn run_judge(
  problem: &ProblemSpec,
  test_case: &TestCaseSpec,
  prepared_solution: &PreparedSolutionSpec,
  official_outputs_dir: &Path,
  workspace: &RuntimeWorkspace,
) -> Result<JudgeReport> {
  let input_path = resolve_test_input(
    problem,
    test_case.input_file.as_deref(),
    test_case.generator.as_deref(),
    test_case.arguments.as_deref(),
    &test_case.name,
  )?;
  let case_dir = workspace.case_dir(
    "judge",
    &format!("{}-{}", prepared_solution.src, test_case.name),
  )?;
  let work_dir = workspace.run_dir(
    "judge",
    &format!("{}-{}", prepared_solution.src, test_case.name),
  )?;
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

  run_judger_script(
    &problem.judger.judge_runner,
    "judge",
    &input_path,
    test_case,
    prepared_solution,
    &outputs_dir,
    Some((official_outputs_dir, &report_path)),
    &work_dir,
  )?;

  let mut report: JudgeReport = serde_json::from_slice(
    &fs::read(&report_path)
      .with_context(|| format!("Failed to read judge report at {}", report_path.display()))?,
  )
  .context("Failed to parse judge report JSON")?;
  report.outputs = outputs_dir.to_string_lossy().into_owned();
  Ok(report)
}

fn run_judger_script(
  runner: &ArtifactSpec,
  mode: &str,
  input_path: &Path,
  test_case: &TestCaseSpec,
  prepared_solution: &PreparedSolutionSpec,
  outputs_dir: &Path,
  judge_context: Option<(&Path, &Path)>,
  work_dir: &Path,
) -> Result<()> {
  // The packaged runners write helper files into their working directory, so
  // each invocation gets an isolated sandbox directory.
  let runner = realize_runner(runner)?;
  let mut command = Command::new(&runner);
  command
    .current_dir(work_dir)
    .env("HULL_MODE", mode)
    .env("HULL_TESTCASE_NAME", &test_case.name)
    .env("HULL_SOLUTION_NAME", &prepared_solution.src)
    .env("HULL_INPUT_PATH", input_path)
    .env("HULL_TICK_LIMIT", test_case.tick_limit.to_string())
    .env("HULL_MEMORY_LIMIT", test_case.memory_limit.to_string())
    .env("HULL_SOLUTION_SRC", &prepared_solution.src)
    .env("HULL_OUTPUTS_DIR", outputs_dir);

  if let Some(executable) = &prepared_solution.executable {
    command.env("HULL_SOLUTION_EXECUTABLE", realize_artifact(executable)?);
  } else {
    command.env_remove("HULL_SOLUTION_EXECUTABLE");
  }

  match judge_context {
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
      "Judger runner '{}' failed. Stdout:\n{}\nStderr:\n{}",
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
        "Failed to realize runner {}. Stderr:\n{}",
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
) -> Vec<SubtaskRuntimeReport> {
  problem
    .subtasks
    .iter()
    .map(|subtask| {
      let test_cases: BTreeMap<_, _> = subtask
        .test_cases
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
      "Input for '{}' is missing both inputFile and generator",
      temp_name
    )
  })?;
  let generator_wasm = problem
    .generators
    .get(generator_name)
    .and_then(|program| program.wasm.as_ref())
    .with_context(|| format!("Generator '{}' is missing `wasm` metadata", generator_name))?;
  let generator_wasm = realize_artifact(generator_wasm)?;
  let result = run_wasm_for_stdio(
    &generator_wasm,
    None,
    arguments.unwrap_or(&[]),
    TOOL_TICK_LIMIT,
    TOOL_MEMORY_LIMIT,
    &[],
  )?;
  let path = std::env::temp_dir().join(format!(
    "hull-generated-input-{}-{temp_name}.txt",
    problem.name
  ));
  fs::write(&path, result.stdout)
    .with_context(|| format!("Failed to write generated input {}", path.display()))?;
  Ok(path)
}
