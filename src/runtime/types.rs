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
use std::fmt;
use std::sync::{
  Arc,
  atomic::{AtomicBool, Ordering},
};

use serde::{Deserialize, Serialize};

use crate::interactive::ProblemProgressHandle;
use crate::platform::default_parallelism;

#[derive(Clone, Debug)]
/// Runtime analysis configuration shared by build, judge, and stress commands.
pub struct RuntimeOptions {
  /// Maximum number of runtime-analysis workers.
  pub jobs: usize,
  /// Progress handle shared by runtime-analysis tasks.
  pub progress: ProblemProgressHandle,
  /// Optional allowlist of solution names to analyze.
  pub solution_names: Option<BTreeSet<String>>,
  /// Whether one failed task requests cancellation of sibling work.
  pub stop_on_failure: bool,
  stop_requested: Arc<AtomicBool>,
}

impl RuntimeOptions {
  /// Creates runtime options with an optional explicit worker count.
  pub fn new(jobs: Option<usize>) -> Self {
    Self {
      jobs: jobs.unwrap_or_else(default_parallelism).max(1),
      progress: ProblemProgressHandle::disabled(),
      solution_names: None,
      stop_on_failure: false,
      stop_requested: Arc::new(AtomicBool::new(false)),
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

  /// Enables or disables fail-fast runtime analysis.
  pub fn with_stop_on_failure(mut self, stop_on_failure: bool) -> Self {
    self.stop_on_failure = stop_on_failure;
    self
  }

  /// Creates child options for one serial problem analysis while sharing cancellation state.
  pub fn single_job_child(&self, progress: ProblemProgressHandle) -> Self {
    Self {
      jobs: 1,
      progress,
      solution_names: self.solution_names.clone(),
      stop_on_failure: self.stop_on_failure,
      stop_requested: self.stop_requested.clone(),
    }
  }

  /// Requests fail-fast cancellation for sibling runtime work.
  pub fn request_stop(&self) {
    if self.stop_on_failure {
      self.stop_requested.store(true, Ordering::Relaxed);
    }
  }

  /// Returns whether fail-fast cancellation has been requested.
  pub fn should_stop(&self) -> bool {
    self.stop_on_failure && self.stop_requested.load(Ordering::Relaxed)
  }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
/// Resolved path metadata for one runtime artifact.
pub struct ArtifactSpec {
  /// Resolved artifact path consumed by a runner.
  pub path: String,
  /// Optional derivation path used to realize the artifact.
  pub drv_path: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
/// Source or artifact description for a problem tool such as a checker or generator.
pub struct ProgramSpec {
  /// Optional source path for the program.
  pub src: Option<String>,
  /// Optional compiled Wasm artifact for the program.
  pub wasm: Option<ArtifactSpec>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
/// Runtime runners that implement Hull's prepare, generate, and judge phases.
pub struct JudgerSpec {
  /// Runner that prepares a submitted solution.
  pub prepare_solution_runner: ArtifactSpec,
  /// Optional runner that generates official outputs.
  pub generate_outputs_runner: Option<ArtifactSpec>,
  /// Runner that judges one prepared solution on one testcase.
  pub judge_runner: ArtifactSpec,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
/// One configured solution in a problem specification.
pub struct SolutionSpec {
  /// Configured solution name.
  pub name: String,
  /// Source path of the solution.
  pub src: String,
  /// Whether this is the authoritative correct solution.
  pub main_correct_solution: bool,
  /// Whether participant-facing packages may include this solution.
  pub participant_visibility: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
/// Prepared solution outputs returned by the prepareSolution runner.
pub struct PreparedSolutionSpec {
  /// Source path retained for the prepared solution.
  pub src: String,
  /// Optional executable artifact produced by preparation.
  pub executable: Option<ArtifactSpec>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
/// One testcase in the runtime problem model.
pub struct TestCaseSpec {
  /// Configured testcase name.
  pub name: String,
  /// Optional manually supplied input path.
  pub input_file: Option<String>,
  /// Per-program execution limit in deterministic ticks.
  pub tick_limit: u64,
  /// Independent byte ceiling for linear memory and the guest stack.
  pub memory_limit: u64,
  /// Named groups containing this testcase.
  pub groups: Vec<String>,
  /// Expected subset of validator-derived traits.
  pub trait_hints: BTreeMap<String, bool>,
  /// Optional generator name used to create the input.
  pub generator: Option<String>,
  /// Optional arguments passed to the generator.
  pub arguments: Option<Vec<String>>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
/// One subtask in the runtime problem model.
pub struct SubtaskSpec {
  /// Fraction of the problem score awarded by this subtask.
  pub full_score: f64,
  /// Method used to combine matching testcase scores.
  pub scoring_method: ScoringMethod,
  /// Validator-derived trait values required for membership.
  pub traits: BTreeMap<String, bool>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
/// Supported subtask score aggregation methods.
pub enum ScoringMethod {
  /// The subtask score is the minimum score among matching test cases.
  Min,
  /// The subtask score is the average score among matching test cases.
  Sum,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
/// One checker self-test specification.
pub struct CheckerTestSpec {
  /// Checker self-test name.
  pub name: String,
  /// Logical name assigned to the candidate output.
  pub output_name: String,
  /// Optional solution used to produce the candidate output.
  pub output_solution: Option<String>,
  /// Optional path supplying the candidate output directly.
  pub output_path: Option<String>,
  /// Optional manually supplied input path.
  pub input_file: Option<String>,
  /// Optional generator name used to create the input.
  pub generator: Option<String>,
  /// Optional arguments passed to the generator.
  pub arguments: Option<Vec<String>>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
/// One validator self-test specification.
pub struct ValidatorTestSpec {
  /// Validator self-test name.
  pub name: String,
  /// Optional manually supplied input path.
  pub input_file: Option<String>,
  /// Optional generator name used to create the input.
  pub generator: Option<String>,
  /// Optional arguments passed to the generator.
  pub arguments: Option<Vec<String>>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
/// Full runtime metadata for one problem.
pub struct ProblemSpec {
  /// Configured problem name.
  pub name: String,
  /// Default per-program execution limit in deterministic ticks.
  pub tick_limit: u64,
  /// Default byte ceiling used independently for linear memory and the guest stack.
  pub memory_limit: u64,
  /// Logical file and cumulative pipe byte ceiling for contestant resources.
  pub file_size_limit: u64,
  /// Total score assigned to the problem.
  pub full_score: f64,
  /// Checker program metadata.
  pub checker: ProgramSpec,
  /// Validator program metadata.
  pub validator: ProgramSpec,
  /// Generator programs indexed by configured name.
  pub generators: BTreeMap<String, ProgramSpec>,
  /// Name of the authoritative correct solution.
  pub main_correct_solution: String,
  /// Runners implementing the problem's judging protocol.
  pub judger: JudgerSpec,
  /// Testcases evaluated for the problem.
  pub test_cases: Vec<TestCaseSpec>,
  /// Subtasks used to aggregate testcase scores.
  pub subtasks: Vec<SubtaskSpec>,
  /// Configured reference and participant solutions.
  pub solutions: Vec<SolutionSpec>,
  /// Checker self-tests evaluated during runtime analysis.
  pub checker_tests: Vec<CheckerTestSpec>,
  /// Validator self-tests evaluated during runtime analysis.
  pub validator_tests: Vec<ValidatorTestSpec>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
/// Full runtime metadata for one contest.
pub struct ContestSpec {
  /// Configured contest name.
  pub name: String,
  /// Problems included in the contest.
  pub problems: Vec<ProblemSpec>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
/// Exported bundle judging contest manifest.
pub struct BundleContestSpec {
  /// Configured contest name.
  pub name: String,
  /// Problem manifests included in the bundle.
  pub problems: Vec<BundleProblemSpec>,
  /// Submission languages accepted by the bundle.
  pub languages: Vec<BundleLanguageSpec>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
/// One problem entry inside a bundle judging contest manifest.
pub struct BundleProblemSpec {
  /// Configured problem name.
  pub name: String,
  /// Total score assigned to the problem.
  pub full_score: f64,
  /// Path to this problem's judging metadata inside the bundle.
  pub metadata_path: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
/// Exported judging metadata consumed by `hull integration-judge uoj` and `bundle-judge`.
pub struct BundleJudgeProblemSpec {
  /// Configured problem name.
  pub name: String,
  /// Default per-program execution limit in deterministic ticks.
  pub tick_limit: u64,
  /// Default byte ceiling used independently for linear memory and the guest stack.
  pub memory_limit: u64,
  /// Logical file and cumulative pipe byte ceiling for contestant resources.
  pub file_size_limit: u64,
  /// Total score assigned to the problem.
  pub full_score: f64,
  #[serde(default = "default_program_spec")]
  /// Checker program metadata.
  pub checker: ProgramSpec,
  #[serde(default = "default_program_spec")]
  /// Validator program metadata.
  pub validator: ProgramSpec,
  /// Runners implementing the problem's judging protocol.
  pub judger: JudgerSpec,
  #[serde(default)]
  /// Name of the authoritative correct solution.
  pub main_correct_solution: String,
  /// Testcases available in the bundle.
  pub test_cases: Vec<BundleJudgeTestCaseSpec>,
  /// Subtasks used to aggregate testcase scores.
  pub subtasks: Vec<SubtaskSpec>,
  #[serde(default)]
  /// Solutions embedded in the bundle metadata.
  pub solutions: Vec<SolutionSpec>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
/// One testcase entry inside exported judging metadata.
pub struct BundleJudgeTestCaseSpec {
  /// Configured testcase name.
  pub name: String,
  /// Per-program execution limit in deterministic ticks.
  pub tick_limit: u64,
  /// Independent byte ceiling for linear memory and the guest stack.
  pub memory_limit: u64,
  /// Named groups containing this testcase.
  pub groups: Vec<String>,
  /// Expected subset of validator-derived traits.
  pub trait_hints: BTreeMap<String, bool>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
/// One language option exposed in a bundle judging bundle.
pub struct BundleLanguageSpec {
  /// Participant-facing language name.
  pub display_name: String,
  /// Filename suffix used to identify submissions in this language.
  pub file_name_suffix: String,
  /// Hull compiler language identifier.
  pub hull_language: String,
}

fn default_program_spec() -> ProgramSpec {
  ProgramSpec {
    src: None,
    wasm: None,
  }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
/// Complete runtime analysis result for one problem.
pub struct RuntimeData {
  /// Checker self-test runtime data.
  pub checker: CheckerRuntimeData,
  /// Generated and validated testcase data indexed by name.
  pub test_cases: BTreeMap<String, RuntimeTestCaseData>,
  /// Validator self-test runtime data.
  pub validator: ValidatorRuntimeData,
  /// Judging results indexed by solution name.
  pub solutions: BTreeMap<String, RuntimeSolutionData>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
/// Runtime checker inputs and checker self-test results.
pub struct CheckerRuntimeData {
  /// Checker self-test input paths indexed by test name.
  pub test_inputs: BTreeMap<String, String>,
  /// Checker self-test results indexed by test name.
  pub test_results: BTreeMap<String, CheckerReport>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
/// Runtime validator inputs and validator self-test results.
pub struct ValidatorRuntimeData {
  /// Validator self-test input paths indexed by test name.
  pub test_inputs: BTreeMap<String, String>,
  /// Validator self-test results indexed by test name.
  pub test_results: BTreeMap<String, ValidationReport>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
/// Packaged files and validation data for one runtime testcase.
pub struct RuntimeTestCaseData {
  /// Packaged input and official-output paths.
  pub data: RuntimeTestCaseFiles,
  /// Validation result for the generated or supplied input.
  pub input_validation: ValidationReport,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
/// Paths to one testcase's packaged input and official outputs.
pub struct RuntimeTestCaseFiles {
  /// Path to the testcase input.
  pub input: String,
  /// Path to the directory containing official outputs.
  pub outputs: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
/// Aggregated judging result for one solution across all testcases and subtasks.
pub struct RuntimeSolutionData {
  /// Per-testcase judging reports indexed by testcase name.
  pub test_case_results: BTreeMap<String, JudgeReport>,
  /// Per-subtask aggregate reports in configured order.
  pub subtask_results: Vec<SubtaskRuntimeReport>,
  /// Total scaled score across all subtasks.
  pub score: f64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
/// Aggregated scoring data for one subtask.
pub struct SubtaskRuntimeReport {
  /// Matching testcase reports indexed by testcase name.
  pub test_cases: BTreeMap<String, JudgeReport>,
  /// Testcase statuses in configured testcase order.
  pub statuses: Vec<JudgeStatus>,
  /// Score before applying the subtask's full-score weight.
  pub raw_score: f64,
  /// Score after applying the subtask's full-score weight.
  pub scaled_score: f64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
/// One testcase status returned by a Hull judger.
pub enum JudgeStatus {
  /// The testcase was accepted.
  Accepted,
  /// The checker rejected the contestant output.
  WrongAnswer,
  /// The checker awarded a score strictly between zero and one.
  PartiallyCorrect,
  /// The contestant program trapped or exited unsuccessfully.
  RuntimeError,
  /// The contestant program exhausted its tick limit.
  TimeLimitExceeded,
  /// The contestant program exceeded its memory limit.
  MemoryLimitExceeded,
  /// A declared file or pipe exceeded its size limit.
  FileError,
  /// Hull could not complete judging because of an infrastructure failure.
  InternalError,
}

impl JudgeStatus {
  /// Returns whether this status should fail internal runtime analysis immediately.
  pub fn is_fatal(self) -> bool {
    self == Self::InternalError
  }

  /// Returns whether logging should include the full report details.
  pub fn needs_detailed_log(self) -> bool {
    self == Self::InternalError
  }

  /// Selects one aggregate status using infrastructure and verdict precedence.
  pub fn aggregate(statuses: impl IntoIterator<Item = Self>) -> Option<Self> {
    statuses.into_iter().max_by_key(|status| match status {
      Self::Accepted => 0,
      Self::PartiallyCorrect => 1,
      Self::WrongAnswer => 2,
      Self::RuntimeError => 3,
      Self::TimeLimitExceeded => 4,
      Self::FileError => 5,
      Self::MemoryLimitExceeded => 6,
      Self::InternalError => 7,
    })
  }
}

impl fmt::Display for JudgeStatus {
  fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
    f.write_str(match self {
      Self::Accepted => "accepted",
      Self::WrongAnswer => "wrong_answer",
      Self::PartiallyCorrect => "partially_correct",
      Self::RuntimeError => "runtime_error",
      Self::TimeLimitExceeded => "time_limit_exceeded",
      Self::MemoryLimitExceeded => "memory_limit_exceeded",
      Self::FileError => "file_error",
      Self::InternalError => "internal_error",
    })
  }
}

impl Ord for JudgeStatus {
  fn cmp(&self, other: &Self) -> std::cmp::Ordering {
    self.to_string().cmp(&other.to_string())
  }
}

impl PartialOrd for JudgeStatus {
  fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
    Some(self.cmp(other))
  }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
/// One testcase judging result returned by a Hull judger.
pub struct JudgeReport {
  /// Final testcase verdict.
  pub status: JudgeStatus,
  /// Normalized testcase score.
  pub score: f64,
  /// Judger-provided diagnostic message.
  pub message: String,
  /// Deterministic ticks consumed by the contestant program.
  pub tick: u64,
  /// Peak linear-memory usage in bytes.
  pub memory: u64,
  #[serde(skip_deserializing)]
  /// Path containing captured contestant outputs for detailed reporting.
  pub outputs: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
/// One input validation status returned by a Hull validator.
pub enum ValidationStatus {
  /// The validator accepted the input.
  Valid,
  /// The validator rejected the input.
  Invalid,
  /// Validation could not complete because of an infrastructure failure.
  InternalError,
}

impl ValidationStatus {
  /// Returns whether validation accepted the input.
  pub fn is_valid(self) -> bool {
    self == Self::Valid
  }

  /// Returns whether this status should fail internal runtime analysis immediately.
  pub fn is_fatal(self) -> bool {
    self == Self::InternalError
  }

  /// Returns whether logging should include the full report details.
  pub fn needs_detailed_log(self) -> bool {
    self == Self::InternalError
  }
}

impl fmt::Display for ValidationStatus {
  fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
    f.write_str(match self {
      Self::Valid => "valid",
      Self::Invalid => "invalid",
      Self::InternalError => "internal_error",
    })
  }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
/// One input validation result and its optional trait annotations.
pub struct ValidationReport {
  /// Final validation status.
  pub status: ValidationStatus,
  /// Validator-provided diagnostic message.
  pub message: String,
  #[serde(default)]
  /// Reader trace stacks emitted by CPLib.
  pub reader_trace_stacks: Vec<serde_json::Value>,
  #[serde(default = "default_json_object")]
  /// Reader trace tree emitted by CPLib.
  pub reader_trace_tree: serde_json::Value,
  #[serde(default)]
  /// Trait values derived from the validated input.
  pub traits: BTreeMap<String, bool>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
/// One checker status returned by a Hull checker.
pub enum CheckerStatus {
  /// The checker accepted the contestant output.
  Accepted,
  /// The checker rejected the contestant output.
  WrongAnswer,
  /// The checker awarded a score strictly between zero and one.
  PartiallyCorrect,
  /// Checking could not complete because of an infrastructure failure.
  InternalError,
}

impl CheckerStatus {
  /// Returns whether this status should fail internal runtime analysis immediately.
  pub fn is_fatal(self) -> bool {
    self == Self::InternalError
  }

  /// Returns whether logging should include the full report details.
  pub fn needs_detailed_log(self) -> bool {
    self == Self::InternalError
  }
}

impl fmt::Display for CheckerStatus {
  fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
    f.write_str(match self {
      Self::Accepted => "accepted",
      Self::WrongAnswer => "wrong_answer",
      Self::PartiallyCorrect => "partially_correct",
      Self::InternalError => "internal_error",
    })
  }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
/// One checker result including score and optional trace data.
pub struct CheckerReport {
  /// Final checker status.
  pub status: CheckerStatus,
  /// Checker-provided diagnostic message.
  pub message: String,
  /// Normalized score awarded by the checker.
  pub score: f64,
  #[serde(default)]
  /// Reader trace stacks emitted by CPLib.
  pub reader_trace_stacks: Vec<serde_json::Value>,
  #[serde(default)]
  /// Evaluator trace stacks emitted by CPLib.
  pub evaluator_trace_stacks: Vec<serde_json::Value>,
}

fn default_json_object() -> serde_json::Value {
  serde_json::json!({})
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn judge_status_json() {
    let err = serde_json::from_str::<JudgeReport>(
      r#"{
        "status": "mysterious_failure",
        "score": 0.0,
        "message": "bad",
        "tick": 0,
        "memory": 0
      }"#,
    )
    .expect_err("unknown judge status must fail at the JSON boundary");

    assert!(err.to_string().contains("unknown variant"));
  }

  #[test]
  fn file_error_json() {
    assert_eq!(
      serde_json::to_string(&JudgeStatus::FileError).unwrap(),
      r#""file_error""#
    );
  }

  #[test]
  fn judge_status_precedence() {
    assert_eq!(
      JudgeStatus::aggregate([
        JudgeStatus::RuntimeError,
        JudgeStatus::TimeLimitExceeded,
        JudgeStatus::FileError,
        JudgeStatus::MemoryLimitExceeded,
      ]),
      Some(JudgeStatus::MemoryLimitExceeded)
    );
    assert_eq!(
      JudgeStatus::aggregate([
        JudgeStatus::RuntimeError,
        JudgeStatus::TimeLimitExceeded,
        JudgeStatus::FileError,
      ]),
      Some(JudgeStatus::FileError)
    );
  }

  #[test]
  fn validator_status_json() {
    let err = serde_json::from_str::<ValidationReport>(
      r#"{
        "status": "maybe_valid",
        "message": "bad"
      }"#,
    )
    .expect_err("unknown validation status must fail at the JSON boundary");

    assert!(err.to_string().contains("unknown variant"));
  }

  #[test]
  fn checker_status_json() {
    let err = serde_json::from_str::<CheckerReport>(
      r#"{
        "status": "maybe_accepted",
        "message": "bad",
        "score": 0.0
      }"#,
    )
    .expect_err("unknown checker status must fail at the JSON boundary");

    assert!(err.to_string().contains("unknown variant"));
  }
}
