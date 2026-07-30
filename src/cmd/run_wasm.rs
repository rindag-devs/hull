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

use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::Parser;

use crate::runner::{self, RunStatus, SessionRequest};

/// Options for executing one deterministic Wasm session request.
#[derive(Parser)]
pub struct RunWasmOpts {
  /// Strict JSON session request; relative paths resolve from this file's directory.
  pub request_path: PathBuf,
}

/// Executes the requested Wasm session and writes its metadata report.
pub fn run(options: &RunWasmOpts) -> Result<()> {
  let request_path = options.request_path.canonicalize().with_context(|| {
    format!(
      "Failed to resolve request {}",
      options.request_path.display()
    )
  })?;
  let request_bytes = std::fs::read(&request_path)
    .with_context(|| format!("Failed to read request {}", request_path.display()))?;
  let mut request: SessionRequest = serde_json::from_slice(&request_bytes)
    .with_context(|| format!("Failed to parse request {}", request_path.display()))?;
  request.resolve_paths(&request_path);

  let report_path = request.report_path.clone();
  let required_accepted = request
    .programs
    .iter()
    .map(|program| (program.name.clone(), program.required_accepted))
    .collect::<Vec<_>>();
  let report = runner::run_session(request);
  runner::write_report(&report_path, &report)
    .with_context(|| format!("Failed to write session report {}", report_path.display()))?;

  let rejected = required_accepted
    .iter()
    .zip(&report.results)
    .filter(|((_, required), result)| *required && result.status != RunStatus::Accepted)
    .map(|((name, _), result)| format!("{name}: {}", result.status))
    .collect::<Vec<_>>();
  if !rejected.is_empty() {
    bail!(
      "Required programs were not accepted: {}. Report: {}",
      rejected.join(", "),
      report_path.display()
    );
  }

  Ok(())
}
