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

mod analysis;
mod artifact;
mod build;
mod metadata;
mod sandbox;
mod types;
mod workspace;

pub use analysis::analyze_problem;
pub use artifact::{cache_native_module, realize_artifact};
pub use build::{build_contest, build_problem};
pub use metadata::{load_ad_hoc_problem_spec, load_contest_spec, load_problem_spec};
pub use sandbox::{WasmRunResult, run_wasm_for_stdio};
pub use types::{
  ArtifactSpec, CheckerReport, CheckerRuntimeData, CheckerTestSpec, ContestSpec, JudgerSpec,
  PreparedSolutionSpec, ProblemSpec, ProgramSpec, RuntimeData, RuntimeOptions, RuntimeSolutionData,
  RuntimeTestCaseData, RuntimeTestCaseFiles, SolutionSpec, SubtaskRuntimeReport, SubtaskSpec,
  TestCaseSpec, ValidationReport, ValidatorRuntimeData, ValidatorTestSpec,
};
pub use workspace::RuntimeWorkspace;
