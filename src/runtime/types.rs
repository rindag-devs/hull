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

use serde::{Deserialize, Serialize};

use crate::interactive::ProblemProgressHandle;
use crate::platform::default_parallelism;

#[derive(Clone, Debug)]
/// Runtime analysis configuration shared by build, judge, and stress commands.
pub struct RuntimeOptions {
  pub jobs: usize,
  pub progress: ProblemProgressHandle,
  pub solution_names: Option<BTreeSet<String>>,
}

impl RuntimeOptions {
  /// Creates runtime options with an optional explicit worker count.
  pub fn new(jobs: Option<usize>) -> Self {
    Self {
      jobs: jobs.unwrap_or_else(default_parallelism).max(1),
      progress: ProblemProgressHandle::disabled(),
      solution_names: None,
    }
  }

  /// Attaches a progress renderer to these runtime options.
  pub fn with_progress(mut self, progress: ProblemProgressHandle) -> Self {
    self.progress = progress;
    self
  }

  /// Restricts runtime analysis to the named solutions when provided.
  pub fn with_solution_names(mut self, solution_names: impl IntoIterator<Item = String>) -> Self {
    self.solution_names = Some(solution_names.into_iter().collect());
    self
  }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Resolved path metadata for one runtime artifact.
pub struct ArtifactSpec {
  pub path: String,
  pub drv_path: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Source or artifact description for a problem tool such as a checker or generator.
pub struct ProgramSpec {
  pub src: Option<String>,
  pub wasm: Option<ArtifactSpec>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Runtime runners that implement Hull's prepare, generate, and judge phases.
pub struct JudgerSpec {
  pub prepare_solution_runner: ArtifactSpec,
  pub generate_outputs_runner: Option<ArtifactSpec>,
  pub judge_runner: ArtifactSpec,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// One configured solution in a problem specification.
pub struct SolutionSpec {
  pub name: String,
  pub src: String,
  pub main_correct_solution: bool,
  pub participant_visibility: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Prepared solution outputs returned by the prepareSolution runner.
pub struct PreparedSolutionSpec {
  pub src: String,
  pub executable: Option<ArtifactSpec>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// One testcase in the runtime problem model.
pub struct TestCaseSpec {
  pub name: String,
  pub input_file: Option<String>,
  pub tick_limit: u64,
  pub memory_limit: u64,
  pub groups: Vec<String>,
  pub trait_hints: BTreeMap<String, bool>,
  pub generator: Option<String>,
  pub arguments: Option<Vec<String>>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// One subtask in the runtime problem model.
pub struct SubtaskSpec {
  pub full_score: f64,
  pub scoring_method: String,
  pub traits: BTreeMap<String, bool>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// One checker self-test specification.
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
/// One validator self-test specification.
pub struct ValidatorTestSpec {
  pub name: String,
  pub input_file: Option<String>,
  pub generator: Option<String>,
  pub arguments: Option<Vec<String>>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Full runtime metadata for one problem.
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
/// Full runtime metadata for one contest.
pub struct ContestSpec {
  pub name: String,
  pub problems: Vec<ProblemSpec>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Exported bundle judging contest manifest.
pub struct BundleContestSpec {
  pub name: String,
  pub problems: Vec<BundleProblemSpec>,
  pub languages: Vec<BundleLanguageSpec>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// One problem entry inside a bundle judging contest manifest.
pub struct BundleProblemSpec {
  pub name: String,
  pub full_score: f64,
  pub metadata_path: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Exported judging metadata consumed by `hull uoj-custom-judge` and `bundle-judge`.
pub struct BundleJudgeProblemSpec {
  pub name: String,
  pub tick_limit: u64,
  pub memory_limit: u64,
  pub full_score: f64,
  #[serde(default)]
  pub participant_hull_language: String,
  #[serde(default = "default_program_spec")]
  pub checker: ProgramSpec,
  #[serde(default = "default_program_spec")]
  pub validator: ProgramSpec,
  pub judger: JudgerSpec,
  #[serde(default)]
  pub main_correct_solution: String,
  pub test_cases: Vec<BundleJudgeTestCaseSpec>,
  pub subtasks: Vec<SubtaskSpec>,
  #[serde(default)]
  pub solutions: Vec<SolutionSpec>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// One testcase entry inside exported judging metadata.
pub struct BundleJudgeTestCaseSpec {
  pub name: String,
  pub tick_limit: u64,
  pub memory_limit: u64,
  pub groups: Vec<String>,
  pub trait_hints: BTreeMap<String, bool>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// One language option exposed in a bundle judging bundle.
pub struct BundleLanguageSpec {
  pub display_name: String,
  pub file_name_suffix: String,
  pub hull_language: String,
}

fn default_program_spec() -> ProgramSpec {
  ProgramSpec {
    src: None,
    wasm: None,
  }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Complete runtime analysis result for one problem.
pub struct RuntimeData {
  pub checker: CheckerRuntimeData,
  pub test_cases: BTreeMap<String, RuntimeTestCaseData>,
  pub validator: ValidatorRuntimeData,
  pub solutions: BTreeMap<String, RuntimeSolutionData>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Runtime checker inputs and checker self-test results.
pub struct CheckerRuntimeData {
  pub test_inputs: BTreeMap<String, String>,
  pub test_results: BTreeMap<String, CheckerReport>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Runtime validator inputs and validator self-test results.
pub struct ValidatorRuntimeData {
  pub test_inputs: BTreeMap<String, String>,
  pub test_results: BTreeMap<String, ValidationReport>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Packaged files and validation data for one runtime testcase.
pub struct RuntimeTestCaseData {
  pub data: RuntimeTestCaseFiles,
  pub input_validation: ValidationReport,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Paths to one testcase's packaged input and official outputs.
pub struct RuntimeTestCaseFiles {
  pub input: String,
  pub outputs: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Aggregated judging result for one solution across all testcases and subtasks.
pub struct RuntimeSolutionData {
  pub test_case_results: BTreeMap<String, JudgeReport>,
  pub subtask_results: Vec<SubtaskRuntimeReport>,
  pub score: f64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Aggregated scoring data for one subtask.
pub struct SubtaskRuntimeReport {
  pub test_cases: BTreeMap<String, JudgeReport>,
  pub statuses: Vec<String>,
  pub raw_score: f64,
  pub scaled_score: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// One testcase judging result returned by a Hull judger.
pub struct JudgeReport {
  pub status: String,
  pub score: f64,
  pub message: String,
  pub tick: u64,
  pub memory: u64,
  #[serde(skip_deserializing)]
  pub outputs: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// One input validation result and its optional trait annotations.
pub struct ValidationReport {
  pub status: String,
  pub message: String,
  #[serde(default)]
  #[serde(alias = "reader_trace_stacks")]
  pub reader_trace_stacks: Vec<serde_json::Value>,
  #[serde(default = "default_json_object")]
  #[serde(alias = "reader_trace_tree")]
  pub reader_trace_tree: serde_json::Value,
  #[serde(default)]
  pub traits: BTreeMap<String, bool>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
/// One checker result including score and optional trace data.
pub struct CheckerReport {
  pub status: String,
  pub message: String,
  pub score: f64,
  #[serde(default)]
  #[serde(alias = "reader_trace_stacks")]
  pub reader_trace_stacks: Vec<serde_json::Value>,
  #[serde(default)]
  #[serde(alias = "evaluator_trace_stacks")]
  pub evaluator_trace_stacks: Vec<serde_json::Value>,
}

fn default_json_object() -> serde_json::Value {
  serde_json::json!({})
}
