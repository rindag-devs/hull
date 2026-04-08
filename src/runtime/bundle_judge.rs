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
use std::ffi::OsStr;
use std::fs;
use std::io::Cursor;
use std::path::Path;

use anyhow::{anyhow, Context, Result};
use base64::Engine;
use serde::{Deserialize, Serialize};
use tar::{Archive, Builder, Header};

use super::analysis::{run_judge, run_prepare_solution, run_validator};
use super::types::{
  BundleJudgeProblemSpec, JudgeReport, PreparedSolutionSpec, ProblemSpec, SolutionSpec,
  TestCaseSpec, ValidationReport,
};
use super::workspace::RuntimeWorkspace;

/// Canonical filename used for bundled official output archives.
pub const OFFICIAL_DATA_TAR_NAME: &str = "official-data.tar";
const OFFICIAL_DATA_TEXT_PREFIX: &str = "HULL_OFFICIAL_DATA_TAR_BASE64_V1\n";

#[derive(Clone, Debug)]
/// Decoded official testcase data extracted from a bundled archive.
pub struct LoadedOfficialData {
  /// Testcase name to use when invoking the bundled Hull judger.
  pub execution_name: String,
  /// Validator result bundled together with the official outputs.
  pub validation: ValidationReport,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct OfficialDataMetadata {
  test_case_name: String,
}

#[derive(Debug)]
/// Prepared runtime state for judging one bundled participant submission.
pub struct BundlePreparedJudgeContext {
  /// Ephemeral workspace for the full bundled judging session.
  pub workspace: RuntimeWorkspace,
  /// Reconstructed runtime problem spec used by Hull's judging pipeline.
  pub runtime_problem: ProblemSpec,
  /// Synthetic participant solution entry inserted into the runtime problem.
  pub participant_solution: SolutionSpec,
  /// Prepared executable or source form returned by `prepareSolution`.
  pub prepared_solution: PreparedSolutionSpec,
}

#[derive(Debug)]
/// One testcase request passed into bundled judging.
pub struct BundleJudgeTestCaseInput<'a> {
  /// Stable testcase name for reporting and workspace naming.
  pub test_case_name: &'a str,
  /// Path to the testcase input file.
  pub input_path: &'a Path,
  /// Path to the bundled official-data archive for this testcase.
  pub official_data_path: &'a Path,
  /// Tick limit forwarded to the bundled judger.
  pub tick_limit: u64,
  /// Memory limit forwarded to the bundled judger.
  pub memory_limit: u64,
  /// Logical testcase groups used by the runtime judger.
  pub groups: Vec<String>,
  /// Optional trait overrides. If empty, traits bundled in official data are used.
  pub trait_hints: BTreeMap<String, bool>,
}

/// Builds a temporary judging context for one bundled participant submission.
pub fn prepare_bundle_judge_context(
  bundle_root: &Path,
  problem: &BundleJudgeProblemSpec,
  submission_file: &Path,
  submission_hull_language: &str,
  participant_solution_name: &str,
) -> Result<BundlePreparedJudgeContext> {
  let workspace = RuntimeWorkspace::new(std::env::temp_dir().join(format!(
    "hull-bundle-judge-{}-{}",
    problem.name,
    std::process::id()
  )))?;
  let participant_source = copy_submission_source(
    &workspace,
    &problem.name,
    submission_file,
    submission_hull_language,
  )?;
  let runtime_problem = make_runtime_problem(
    bundle_root,
    problem,
    &participant_source,
    participant_solution_name,
  );
  let participant_solution = runtime_problem
    .solutions
    .iter()
    .find(|solution| solution.name == participant_solution_name)
    .cloned()
    .with_context(|| {
      format!(
        "Bundle runtime problem `{}` is missing participant solution `{}`",
        problem.name, participant_solution_name
      )
    })?;
  let prepared_solution = run_prepare_solution(&runtime_problem, &participant_solution, &workspace)
    .with_context(|| {
      format!(
        "Prepare solution failed for bundle problem `{}`, participant solution `{}`",
        problem.name, participant_solution_name
      )
    })?;
  Ok(BundlePreparedJudgeContext {
    workspace,
    runtime_problem,
    participant_solution,
    prepared_solution,
  })
}

/// Reconstructs the runtime `ProblemSpec` from exported bundle metadata.
pub fn make_runtime_problem(
  bundle_root: &Path,
  problem: &BundleJudgeProblemSpec,
  participant_source: &str,
  participant_solution_name: &str,
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
    solutions: build_runtime_solutions(
      bundle_root,
      problem,
      participant_source,
      participant_solution_name,
    ),
    checker_tests: Vec::new(),
    validator_tests: Vec::new(),
  }
}

/// Builds the runtime solution list used by bundled judging.
pub fn build_runtime_solutions(
  bundle_root: &Path,
  problem: &BundleJudgeProblemSpec,
  participant_source: &str,
  participant_solution_name: &str,
) -> Vec<SolutionSpec> {
  let mut solutions = problem
    .solutions
    .iter()
    .filter(|solution| solution.main_correct_solution)
    .map(|solution| SolutionSpec {
      src: resolve_bundled_path(bundle_root, &solution.src),
      ..solution.clone()
    })
    .collect::<Vec<_>>();
  solutions.push(SolutionSpec {
    name: participant_solution_name.to_string(),
    src: participant_source.to_string(),
    main_correct_solution: false,
    participant_visibility: true,
  });
  solutions
}

/// Resolves one bundled path relative to the bundle root when needed.
pub fn resolve_bundled_path(bundle_root: &Path, path: &str) -> String {
  if Path::new(path).is_absolute() {
    path.to_string()
  } else {
    bundle_root.join(path).to_string_lossy().into_owned()
  }
}

/// Copies one participant submission into the bundle judging workspace.
pub fn copy_submission_source(
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
      "Failed to copy bundled submission {} into runtime workspace",
      submission_file.display()
    )
  })?;
  Ok(target.to_string_lossy().into_owned())
}

/// Optionally validates one bundled input file before judging.
pub fn validate_input(
  runtime_problem: &ProblemSpec,
  input_path: &Path,
  validate_input: bool,
) -> Result<Option<ValidationReport>> {
  if !validate_input {
    return Ok(None);
  }
  let report = run_validator(runtime_problem, input_path, 1).with_context(|| {
    format!(
      "Failed to validate bundled testcase input {} for problem `{}`",
      input_path.display(),
      runtime_problem.name
    )
  })?;
  Ok(Some(report))
}

/// Judges one testcase from explicit bundled input and official-data paths.
pub fn judge_test_case_from_paths(
  prepared: &BundlePreparedJudgeContext,
  test_case: BundleJudgeTestCaseInput<'_>,
) -> Result<JudgeReport> {
  let local_case_dir = prepared
    .workspace
    .root()
    .join("bundle-data")
    .join(sanitize_path_component(&format!(
      "{}-{}",
      prepared.runtime_problem.name, test_case.test_case_name
    )));
  fs::create_dir_all(&local_case_dir)?;
  let local_input_path = local_case_dir.join("input");
  fs::copy(test_case.input_path, &local_input_path).with_context(|| {
    format!(
      "Failed to copy testcase input {} to {}",
      test_case.input_path.display(),
      local_input_path.display()
    )
  })?;
  let official_outputs_dir = local_case_dir.join("outputs");
  let loaded = load_official_data(test_case.official_data_path, Some(&official_outputs_dir))?;
  let runtime_test_case = TestCaseSpec {
    name: if loaded.execution_name.is_empty() {
      test_case.test_case_name.to_string()
    } else {
      loaded.execution_name
    },
    input_file: Some(local_input_path.to_string_lossy().into_owned()),
    tick_limit: test_case.tick_limit,
    memory_limit: test_case.memory_limit,
    groups: test_case.groups,
    trait_hints: if test_case.trait_hints.is_empty() {
      loaded.validation.traits
    } else {
      test_case.trait_hints
    },
    generator: None,
    arguments: None,
  };
  run_judge(
    &prepared.runtime_problem,
    &runtime_test_case,
    &prepared.participant_solution.name,
    &prepared.prepared_solution,
    &official_outputs_dir,
    &prepared.workspace,
  )
}

/// Loads one bundled official-data archive and optionally unpacks its outputs.
pub fn load_official_data(
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
      .unwrap_or_default(),
    validation: validation.context("official data tar is missing validation.json")?,
  })
}

/// Packs validator output and generated official outputs into one archive.
pub fn pack_official_data_tar(
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

/// Packs a directory tree into a tar payload.
pub fn pack_directory_to_tar(root_dir: &Path) -> Result<Vec<u8>> {
  let mut builder = Builder::new(Vec::new());
  append_directory_to_tar(&mut builder, root_dir, root_dir)?;
  builder
    .finish()
    .context("Failed to finalize directory tar")?;
  builder
    .into_inner()
    .context("Failed to extract directory tar bytes")
}

/// Unpacks a tar payload into the destination directory.
pub fn unpack_directory_from_tar(tar_bytes: &[u8], dest_dir: &Path) -> Result<()> {
  fs::create_dir_all(dest_dir)?;
  let mut archive = Archive::new(Cursor::new(tar_bytes));
  archive
    .unpack(dest_dir)
    .with_context(|| format!("Failed to unpack tar payload into {}", dest_dir.display()))
}

/// Reads one armored text file into bytes.
pub fn read_armored_payload(path: &Path) -> Result<Vec<u8>> {
  let content = fs::read_to_string(path)
    .with_context(|| format!("Failed to read armored payload {}", path.display()))?;
  let encoded = content.lines().collect::<String>();
  base64::engine::general_purpose::STANDARD
    .decode(encoded)
    .with_context(|| format!("Failed to decode armored payload {}", path.display()))
}

/// Writes bytes as a line-wrapped base64 text file.
pub fn write_armored_payload(path: &Path, bytes: &[u8]) -> Result<()> {
  if let Some(parent) = path.parent() {
    fs::create_dir_all(parent)?;
  }
  let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
  let mut armored = String::new();
  for chunk in encoded.as_bytes().chunks(76) {
    armored.push_str(std::str::from_utf8(chunk).context("Base64 chunk was not UTF-8")?);
    armored.push('\n');
  }
  fs::write(path, armored)
    .with_context(|| format!("Failed to write armored payload {}", path.display()))
}

fn append_directory_to_tar(
  builder: &mut Builder<Vec<u8>>,
  root_dir: &Path,
  current_dir: &Path,
) -> Result<()> {
  for entry in fs::read_dir(current_dir)
    .with_context(|| format!("Failed to read directory {}", current_dir.display()))?
  {
    let entry = entry?;
    let path = entry.path();
    let file_type = entry.file_type()?;
    if file_type.is_dir() {
      append_directory_to_tar(builder, root_dir, &path)?;
      continue;
    }
    if !file_type.is_file() {
      continue;
    }
    let relative = path
      .strip_prefix(root_dir)
      .with_context(|| format!("Failed to relativize path {}", path.display()))?;
    builder
      .append_path_with_name(&path, relative)
      .with_context(|| format!("Failed to append file {} to tar payload", path.display()))?;
  }
  Ok(())
}

/// Reads one bundled official-data payload, decoding armored text when needed.
pub fn read_official_data_payload(official_data_path: &Path) -> Result<Vec<u8>> {
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

/// Writes one bundled official-data payload as raw tar or armored text.
pub fn write_official_data_payload(target_path: &Path, tar_bytes: &[u8]) -> Result<()> {
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

fn sanitize_path_component(value: &str) -> String {
  let sanitized = value
    .chars()
    .map(|ch| {
      if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
        ch
      } else {
        '-'
      }
    })
    .collect::<String>();
  if sanitized.is_empty() {
    "case".to_string()
  } else {
    sanitized
  }
}

/// Builds a consistent unsupported-language error for bundle-based adapters.
pub fn missing_language_error(language: &str, system_name: &str) -> anyhow::Error {
  anyhow!(
    "{system_name} language `{language}` is configured as unsupported because Hull's bundled judger does not support it"
  )
}
