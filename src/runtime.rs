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

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use tracing::info;
use wasi_common::{
  pipe::{ReadPipe, WritePipe},
  WasiFile,
};

use crate::runner::{self, RunStatus};

fn workspace_flake_ref() -> Result<String> {
  let cwd = std::env::current_dir().context("Failed to determine current directory")?;
  Ok(cwd.to_string_lossy().into_owned())
}

pub fn realize_artifact(artifact: &ArtifactSpec) -> Result<String> {
  if Path::new(&artifact.path).exists() {
    return Ok(artifact.path.clone());
  }

  if let Some(drv_path) = &artifact.drv_path {
    let output = Command::new("nix")
      .args(["build", "--no-link", &format!("{drv_path}^*")])
      .output()
      .with_context(|| format!("Failed to realize derivation {}", drv_path))?;
    if !output.status.success() {
      bail!(
        "Failed to realize artifact {}. Stderr:\n{}",
        artifact.path,
        String::from_utf8_lossy(&output.stderr).trim()
      );
    }
  }

  if Path::new(&artifact.path).exists() {
    Ok(artifact.path.clone())
  } else {
    let parent = Path::new(&artifact.path)
      .parent()
      .with_context(|| format!("Artifact path {} has no parent", artifact.path))?;
    let output = Command::new("nix")
      .args(["build", "--no-link", parent.to_string_lossy().as_ref()])
      .output()
      .with_context(|| format!("Failed to realize parent path {}", parent.display()))?;
    if !output.status.success() {
      bail!(
        "Failed to realize artifact {}. Stderr:\n{}",
        artifact.path,
        String::from_utf8_lossy(&output.stderr).trim()
      );
    }

    if Path::new(&artifact.path).exists() {
      Ok(artifact.path.clone())
    } else {
      bail!(
        "Artifact path {} does not exist after realization",
        artifact.path
      )
    }
  }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtifactSpec {
  pub path: String,
  pub drv_path: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProgramSpec {
  pub src: Option<String>,
  pub wasm: Option<ArtifactSpec>,
  pub cwasm: Option<ArtifactSpec>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JudgerSpec {
  pub generate_outputs_runner: ArtifactSpec,
  pub judge_runner: ArtifactSpec,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedSolutionSpec {
  pub src: String,
  pub executable: Option<ArtifactSpec>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SolutionSpec {
  pub name: String,
  pub src: String,
  pub main_correct_solution: bool,
  pub participant_visibility: bool,
  pub prepared: PreparedSolutionSpec,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TestCaseSpec {
  pub name: String,
  pub input_file: Option<String>,
  pub tick_limit: u64,
  pub memory_limit: u64,
  pub groups: Vec<String>,
  pub traits: BTreeMap<String, bool>,
  pub generator: Option<String>,
  pub arguments: Option<Vec<String>>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubtaskSpec {
  pub full_score: f64,
  pub scoring_method: String,
  pub test_cases: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckerTestSpec {
  pub name: String,
  pub output_name: String,
  pub output_solution: Option<String>,
  pub output_path: Option<String>,
  pub input_file: Option<String>,
  pub generator: Option<String>,
  pub arguments: Option<Vec<String>>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ValidatorTestSpec {
  pub name: String,
  pub input_file: Option<String>,
  pub generator: Option<String>,
  pub arguments: Option<Vec<String>>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProblemSpec {
  pub name: String,
  pub tick_limit: u64,
  pub memory_limit: u64,
  pub full_score: f64,
  pub checker: ProgramSpec,
  pub validator: ProgramSpec,
  pub generators: BTreeMap<String, ProgramSpec>,
  pub main_correct_solution: String,
  pub judger: JudgerSpec,
  pub test_cases: Vec<TestCaseSpec>,
  pub subtasks: Vec<SubtaskSpec>,
  pub solutions: Vec<SolutionSpec>,
  pub checker_tests: Vec<CheckerTestSpec>,
  pub validator_tests: Vec<ValidatorTestSpec>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContestSpec {
  pub name: String,
  pub problem_names: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeData {
  pub checker: CheckerRuntimeData,
  pub test_cases: BTreeMap<String, RuntimeTestCaseData>,
  pub validator: ValidatorRuntimeData,
  pub solutions: BTreeMap<String, RuntimeSolutionData>,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckerRuntimeData {
  pub test_results: BTreeMap<String, CheckerReport>,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ValidatorRuntimeData {
  pub test_results: BTreeMap<String, ValidationReport>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeTestCaseData {
  pub data: RuntimeTestCaseFiles,
  pub input_validation: ValidationReport,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeTestCaseFiles {
  pub outputs: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeSolutionData {
  pub test_case_results: BTreeMap<String, JudgeReport>,
  pub subtask_results: Vec<SubtaskRuntimeReport>,
  pub score: f64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubtaskRuntimeReport {
  pub test_cases: BTreeMap<String, JudgeReport>,
  pub statuses: Vec<String>,
  pub raw_score: f64,
  pub scaled_score: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JudgeReport {
  pub status: String,
  pub score: f64,
  pub message: String,
  pub tick: u64,
  pub memory: u64,
  #[serde(default)]
  pub outputs: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ValidationReport {
  pub status: String,
  pub message: String,
  #[serde(default)]
  pub reader_trace_stacks: Vec<serde_json::Value>,
  #[serde(default = "default_json_object")]
  pub reader_trace_tree: serde_json::Value,
  #[serde(default)]
  pub traits: BTreeMap<String, bool>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckerReport {
  pub status: String,
  pub message: String,
  pub score: f64,
  #[serde(default)]
  pub reader_trace_stacks: Vec<serde_json::Value>,
  #[serde(default)]
  pub evaluator_trace_stacks: Vec<serde_json::Value>,
}

fn default_json_object() -> serde_json::Value {
  serde_json::json!({})
}

#[derive(Clone, Debug)]
pub struct RuntimeWorkspace {
  pub root: PathBuf,
}

impl RuntimeWorkspace {
  pub fn new(root: impl Into<PathBuf>) -> Result<Self> {
    let root = root.into();
    fs::create_dir_all(&root)
      .with_context(|| format!("Failed to create runtime workspace {}", root.display()))?;
    Ok(Self { root })
  }

  pub fn case_dir(&self, group: &str, name: &str) -> Result<PathBuf> {
    let safe_name: String = name
      .chars()
      .map(|ch| match ch {
        'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' | '.' => ch,
        _ => '_',
      })
      .collect();
    let path = self.root.join(group).join(safe_name);
    fs::create_dir_all(&path)
      .with_context(|| format!("Failed to create workspace directory {}", path.display()))?;
    Ok(path)
  }

  pub fn run_dir(&self, group: &str, name: &str) -> Result<PathBuf> {
    let path = self.case_dir(group, name)?;
    let run_dir = path.join("work");
    if run_dir.exists() {
      fs::remove_dir_all(&run_dir)
        .with_context(|| format!("Failed to reset run directory {}", run_dir.display()))?;
    }
    fs::create_dir_all(&run_dir)
      .with_context(|| format!("Failed to create run directory {}", run_dir.display()))?;
    Ok(run_dir)
  }
}

pub fn load_problem_spec(problem: &str) -> Result<ProblemSpec> {
  let flake_ref = workspace_flake_ref()?;
  let expr = format!(
    r#"
      let
        flake = builtins.getFlake {flake_ref};
      in
      builtins.toJSON ((flake.inputs.hull.lib or flake.outputs.lib).${{builtins.currentSystem}}.runtime.problemMetadata flake.outputs.hullProblems.${{builtins.currentSystem}}.{problem}.config {{ }})
    "#,
    flake_ref = serde_json::to_string(&flake_ref)?,
  );

  let output = Command::new("nix")
    .args(["eval", "--raw", "--impure", "--expr", &expr])
    .output()
    .context("Failed to execute `nix eval` for runtime problem metadata")?;

  if !output.status.success() {
    bail!(
      "Failed to evaluate runtime problem metadata. Stderr:\n{}",
      String::from_utf8_lossy(&output.stderr).trim()
    );
  }

  serde_json::from_slice(&output.stdout).context("Failed to parse runtime problem metadata JSON")
}

pub fn load_ad_hoc_problem_spec(problem: &str, src_path: &Path) -> Result<ProblemSpec> {
  let flake_ref = workspace_flake_ref()?;
  let expr = format!(
    r#"
      let
        flake = builtins.getFlake {flake_ref};
      in
      builtins.toJSON ((flake.inputs.hull.lib or flake.outputs.lib).${{builtins.currentSystem}}.runtime.adHocProblemMetadata flake.outputs.hullProblems.${{builtins.currentSystem}}.{problem}.config {src_path})
    "#,
    flake_ref = serde_json::to_string(&flake_ref)?,
    src_path = serde_json::to_string(&src_path.to_string_lossy().into_owned())?,
  );

  let output = Command::new("nix")
    .args(["eval", "--raw", "--impure", "--expr", &expr])
    .output()
    .context("Failed to execute `nix eval` for ad-hoc runtime problem metadata")?;

  if !output.status.success() {
    bail!(
      "Failed to evaluate ad-hoc runtime problem metadata. Stderr:\n{}",
      String::from_utf8_lossy(&output.stderr).trim()
    );
  }

  serde_json::from_slice(&output.stdout)
    .context("Failed to parse ad-hoc runtime problem metadata JSON")
}

pub fn load_contest_spec(contest: &str) -> Result<ContestSpec> {
  let flake_ref = workspace_flake_ref()?;
  let expr = format!(
    r#"
      let
        flake = builtins.getFlake {flake_ref};
      in
      builtins.toJSON ((flake.inputs.hull.lib or flake.outputs.lib).${{builtins.currentSystem}}.runtime.contestMetadata flake.outputs.hullContests.${{builtins.currentSystem}}.{contest}.config)
    "#,
    flake_ref = serde_json::to_string(&flake_ref)?,
  );

  let output = Command::new("nix")
    .args(["eval", "--raw", "--impure", "--expr", &expr])
    .output()
    .context("Failed to execute `nix eval` for runtime contest metadata")?;

  if !output.status.success() {
    bail!(
      "Failed to evaluate runtime contest metadata. Stderr:\n{}",
      String::from_utf8_lossy(&output.stderr).trim()
    );
  }

  serde_json::from_slice(&output.stdout).context("Failed to parse runtime contest metadata JSON")
}

pub fn analyze_problem(problem: &ProblemSpec, workspace: &RuntimeWorkspace) -> Result<RuntimeData> {
  let mut runtime = RuntimeData {
    checker: CheckerRuntimeData::default(),
    test_cases: BTreeMap::new(),
    validator: ValidatorRuntimeData::default(),
    solutions: BTreeMap::new(),
  };

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

  for test in &problem.validator_tests {
    info!("Running validator test {}", test.name);
    let input_path = resolve_test_input(
      problem,
      test.input_file.as_deref(),
      test.generator.as_deref(),
      test.arguments.as_deref(),
      &format!("validator-test-{}", test.name),
    )?;
    let report = run_validator(problem, &input_path, 1)?;
    runtime
      .validator
      .test_results
      .insert(test.name.clone(), report);
  }

  let mut official_output_dirs = BTreeMap::new();
  for test_case in &problem.test_cases {
    info!("Preparing test case {}", test_case.name);
    let input_path = resolve_test_input(
      problem,
      test_case.input_file.as_deref(),
      test_case.generator.as_deref(),
      test_case.arguments.as_deref(),
      &test_case.name,
    )?;
    let trace_level = if test_case.groups.iter().any(|group| group == "sample") {
      2
    } else {
      1
    };
    let validation = run_validator(problem, Path::new(&input_path), trace_level)?;
    let outputs_dir = run_generate_outputs(problem, test_case, &main_solution.prepared, workspace)?;
    official_output_dirs.insert(test_case.name.clone(), outputs_dir.clone());
    runtime.test_cases.insert(
      test_case.name.clone(),
      RuntimeTestCaseData {
        data: RuntimeTestCaseFiles {
          outputs: outputs_dir.to_string_lossy().into_owned(),
        },
        input_validation: validation,
      },
    );
  }

  for test in &problem.checker_tests {
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
    runtime
      .checker
      .test_results
      .insert(test.name.clone(), report);
  }

  for solution in &problem.solutions {
    info!("Judging solution {}", solution.name);
    let mut test_case_results = BTreeMap::new();

    for test_case in &problem.test_cases {
      let official_outputs_dir = official_output_dirs.get(&test_case.name).with_context(|| {
        format!(
          "Missing official outputs for test case '{}'",
          test_case.name
        )
      })?;
      let report = run_judge(
        problem,
        test_case,
        &solution.prepared,
        official_outputs_dir,
        workspace,
      )?;
      test_case_results.insert(test_case.name.clone(), report);
    }

    let subtask_results = aggregate_subtask_results(problem, &test_case_results);
    let score = subtask_results
      .iter()
      .map(|result| result.scaled_score)
      .sum();
    runtime.solutions.insert(
      solution.name.clone(),
      RuntimeSolutionData {
        test_case_results,
        subtask_results,
        score,
      },
    );
  }

  Ok(runtime)
}

pub fn render_runtime_json(runtime: &RuntimeData) -> Result<String> {
  serde_json::to_string(runtime).context("Failed to serialize runtime analysis JSON")
}

pub fn add_path_to_store(path: &str) -> Result<String> {
  if path.starts_with("/nix/store/") {
    return Ok(path.to_string());
  }

  let output = Command::new("nix-store")
    .args(["--add", path])
    .output()
    .with_context(|| format!("Failed to add path {} to the Nix store", path))?;

  if !output.status.success() {
    bail!(
      "Failed to add path {} to the Nix store. Stderr:\n{}",
      path,
      String::from_utf8_lossy(&output.stderr).trim()
    );
  }

  Ok(
    String::from_utf8(output.stdout)
      .context("Failed to parse nix-store output as UTF-8")?
      .trim()
      .to_string(),
  )
}

pub fn storeify_runtime_data(runtime: &mut RuntimeData) -> Result<()> {
  for test_case in runtime.test_cases.values_mut() {
    test_case.data.outputs = add_path_to_store(&test_case.data.outputs)?;
  }

  for solution in runtime.solutions.values_mut() {
    for test_case_result in solution.test_case_results.values_mut() {
      test_case_result.outputs = add_path_to_store(&test_case_result.outputs)?;
    }

    for subtask_result in &mut solution.subtask_results {
      for test_case_result in subtask_result.test_cases.values_mut() {
        test_case_result.outputs = add_path_to_store(&test_case_result.outputs)?;
      }
    }
  }

  Ok(())
}

pub fn build_problem_target(
  problem: &str,
  target: &str,
  runtime: &RuntimeData,
  out_link: &str,
) -> Result<()> {
  let flake_ref = workspace_flake_ref()?;
  let mut runtime = runtime.clone();
  storeify_runtime_data(&mut runtime)?;
  let runtime_json = render_runtime_json(&runtime)?;
  let expr = format!(
    r#"
      let
        flake = builtins.getFlake {flake_ref};
        lib = flake.inputs.hull.lib or flake.outputs.lib;
        problemConfig = flake.outputs.hullProblems.${{builtins.currentSystem}}.{problem}.config;
      in
      lib.${{builtins.currentSystem}}.runtime.buildProblemTarget problemConfig (builtins.fromJSON {runtime_json}) {target}
    "#,
    flake_ref = serde_json::to_string(&flake_ref)?,
    runtime_json = serde_json::to_string(&runtime_json)?,
    target = serde_json::to_string(target)?,
  );
  crate::nix::BuildCommand::new()
    .impure(true)
    .expr(&expr)
    .out_link(out_link)
    .run()
}

pub fn build_contest_target(
  contest: &str,
  target: &str,
  runtime_by_problem: &BTreeMap<String, RuntimeData>,
  out_link: &str,
) -> Result<()> {
  let flake_ref = workspace_flake_ref()?;
  let mut runtime_by_problem = runtime_by_problem.clone();
  for runtime in runtime_by_problem.values_mut() {
    storeify_runtime_data(runtime)?;
  }
  let runtime_json = serde_json::to_string(&runtime_by_problem)
    .context("Failed to serialize contest runtime analysis JSON")?;
  let expr = format!(
    r#"
      let
        flake = builtins.getFlake {flake_ref};
        lib = flake.inputs.hull.lib or flake.outputs.lib;
        contestConfig = flake.outputs.hullContests.${{builtins.currentSystem}}.{contest}.config;
      in
      lib.${{builtins.currentSystem}}.runtime.buildContestTarget contestConfig (builtins.fromJSON {runtime_json}) {target}
    "#,
    flake_ref = serde_json::to_string(&flake_ref)?,
    runtime_json = serde_json::to_string(&runtime_json)?,
    target = serde_json::to_string(target)?,
  );
  crate::nix::BuildCommand::new()
    .impure(true)
    .expr(&expr)
    .out_link(out_link)
    .run()
}

pub fn build_problem(problem: &str, target: &str, out_link: &str) -> Result<()> {
  let spec = load_problem_spec(problem)?;
  let workspace =
    RuntimeWorkspace::new(std::env::temp_dir().join(format!("hull-build-{problem}")))?;
  let runtime = analyze_problem(&spec, &workspace)?;
  build_problem_target(problem, target, &runtime, out_link)
}

pub fn build_contest(contest: &str, target: &str, out_link: &str) -> Result<()> {
  let contest_spec = load_contest_spec(contest)?;
  let mut runtime_by_problem = BTreeMap::new();
  for problem_name in &contest_spec.problem_names {
    let spec = load_problem_spec(problem_name)?;
    let workspace = RuntimeWorkspace::new(
      std::env::temp_dir().join(format!("hull-build-contest-{contest}-{problem_name}")),
    )?;
    runtime_by_problem.insert(problem_name.clone(), analyze_problem(&spec, &workspace)?);
  }
  build_contest_target(contest, target, &runtime_by_problem, out_link)
}

fn run_validator(
  problem: &ProblemSpec,
  input_path: &Path,
  reader_trace_level: u8,
) -> Result<ValidationReport> {
  let validator_cwasm = realize_artifact(
    problem
      .validator
      .cwasm
      .as_ref()
      .context("Validator metadata is missing `cwasm`")?,
  )?;

  let result = run_wasm(
    &validator_cwasm,
    Some(input_path),
    &[format!("--reader-trace-level={reader_trace_level}")],
    problem.tick_limit,
    problem.memory_limit,
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
  let checker_cwasm = realize_artifact(
    problem
      .checker
      .cwasm
      .as_ref()
      .context("Checker metadata is missing `cwasm`")?,
  )?;

  let mount = vec![
    (input_path.to_path_buf(), "input".to_string()),
    (output_path.to_path_buf(), "output".to_string()),
    (answer_path.to_path_buf(), "answer".to_string()),
  ];

  let result = run_wasm(
    &checker_cwasm,
    None,
    &[
      "input".to_string(),
      "output".to_string(),
      "answer".to_string(),
    ],
    problem.tick_limit,
    problem.memory_limit,
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
  if let Some(path) = input_file {
    return Ok(PathBuf::from(path));
  }

  let generator_name = generator_name.with_context(|| {
    format!(
      "Input for '{}' is missing both inputFile and generator",
      temp_name
    )
  })?;
  let generator_cwasm = problem
    .generators
    .get(generator_name)
    .and_then(|program| program.cwasm.as_ref())
    .with_context(|| format!("Generator '{}' is missing `cwasm` metadata", generator_name))?;
  let generator_cwasm = realize_artifact(generator_cwasm)?;
  let result = run_wasm_for_stdio(
    &generator_cwasm,
    None,
    arguments.unwrap_or(&[]),
    u64::MAX,
    u32::MAX as u64,
    &[],
  )?;
  let path = std::env::temp_dir().join(format!("hull-generated-input-{temp_name}.txt"));
  fs::write(&path, result.stdout)
    .with_context(|| format!("Failed to write generated input {}", path.display()))?;
  Ok(path)
}

pub struct WasmRunResult {
  pub status: RunStatus,
  pub tick: u64,
  pub memory: u64,
  pub error_message: String,
  pub stdout: Vec<u8>,
  pub stderr: Vec<u8>,
}

pub fn run_wasm_for_stdio(
  wasm_path: &str,
  stdin_path: Option<&Path>,
  arguments: &[String],
  tick_limit: u64,
  memory_limit: u64,
  read_files: &[(PathBuf, String)],
) -> Result<WasmRunResult> {
  let wasm_bytes =
    fs::read(wasm_path).with_context(|| format!("Failed to read WASM artifact {}", wasm_path))?;

  let stdin: Box<dyn WasiFile> = match stdin_path {
    Some(path) => Box::new(ReadPipe::from(
      fs::read(path)
        .with_context(|| format!("Failed to read stdin file {}", path.display()))?
        .as_slice(),
    )),
    None => Box::new(ReadPipe::new(std::io::empty())),
  };

  let stdout_pipe = WritePipe::new_in_memory();
  let stderr_pipe = WritePipe::new_in_memory();
  let stdout_capture = stdout_pipe.clone();
  let stderr_capture = stderr_pipe.clone();

  let preopened_dir = if read_files.is_empty() {
    None
  } else {
    let mappings = read_files
      .iter()
      .map(|(src, dest)| Ok((src.clone(), dest.clone())))
      .collect::<Result<Vec<_>>>()?;
    let judge_dir = crate::runner::judge_dir::JudgeDir::from_mappings(&mappings, &[])?;
    Some(Box::new(judge_dir) as Box<dyn wasi_common::WasiDir>)
  };

  let result = runner::run(
    &wasm_bytes,
    arguments,
    tick_limit,
    memory_limit,
    [stdin, Box::new(stdout_pipe), Box::new(stderr_pipe)],
    preopened_dir,
  );

  let stdout = stdout_capture
    .try_into_inner()
    .map_err(|_| anyhow::anyhow!("Failed to capture stdout buffer"))?
    .into_inner();
  let stderr = stderr_capture
    .try_into_inner()
    .map_err(|_| anyhow::anyhow!("Failed to capture stderr buffer"))?
    .into_inner();

  Ok(WasmRunResult {
    status: result.status,
    tick: result.tick,
    memory: result.memory,
    error_message: result.error_message,
    stdout,
    stderr,
  })
}

fn run_wasm(
  wasm_path: &str,
  stdin_path: Option<&Path>,
  arguments: &[String],
  tick_limit: u64,
  memory_limit: u64,
  read_files: &[(PathBuf, String)],
) -> Result<WasmRunResult> {
  run_wasm_for_stdio(
    wasm_path,
    stdin_path,
    arguments,
    tick_limit,
    memory_limit,
    read_files,
  )
}
