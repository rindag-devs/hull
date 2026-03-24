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

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug)]
pub struct RuntimeOptions {
  pub jobs: usize,
}

impl RuntimeOptions {
  pub fn new(jobs: Option<usize>) -> Self {
    Self {
      jobs: jobs.unwrap_or_else(num_cpus::get).max(1),
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
  pub problems: Vec<ProblemSpec>,
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
  pub test_inputs: BTreeMap<String, String>,
  pub test_results: BTreeMap<String, CheckerReport>,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ValidatorRuntimeData {
  pub test_inputs: BTreeMap<String, String>,
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
  pub input: String,
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

pub fn default_json_object() -> serde_json::Value {
  serde_json::json!({})
}
