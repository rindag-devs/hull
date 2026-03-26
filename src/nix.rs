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

use std::collections::HashMap;
use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail};
use serde::Deserialize;

use crate::interactive::{self, ProblemProgressHandle};

#[derive(Deserialize)]
pub struct FlakeMetadata {
  url: String,
}

/// Get the flake URL for the current directory by running `nix flake metadata`.
pub fn get_flake_url() -> Result<String> {
  let output = Command::new("nix")
    .args(["flake", "metadata", ".", "--json"])
    .output()
    .context("Failed to execute `nix flake metadata`")?;

  if !output.status.success() {
    let stderr = String::from_utf8_lossy(&output.stderr);
    bail!("Failed to get flake metadata. Stderr:\n{}", stderr.trim());
  }

  let metadata_str = String::from_utf8(output.stdout)
    .context("Failed to parse `nix flake metadata` output as UTF-8")?;

  let metadata: FlakeMetadata = serde_json::from_str(&metadata_str)
    .context("Failed to parse JSON from `nix flake metadata`")?;

  Ok(metadata.url)
}

pub struct EvalCommand {
  expr: Option<String>,
  impure: bool,
  raw: bool,
  with_nom: bool,
}

impl EvalCommand {
  pub fn new() -> Self {
    Self {
      expr: None,
      impure: false,
      raw: true,
      with_nom: interactive::current_settings().enabled(),
    }
  }

  pub fn expr(mut self, expr: &str) -> Self {
    self.expr = Some(expr.to_string());
    self
  }

  pub fn impure(mut self, impure: bool) -> Self {
    self.impure = impure;
    self
  }

  pub fn raw(mut self, raw: bool) -> Self {
    self.raw = raw;
    self
  }

  pub fn with_nom(mut self, with_nom: bool) -> Self {
    self.with_nom = with_nom;
    self
  }

  fn build_command(&self) -> Command {
    let mut cmd = Command::new("nix");
    cmd.arg("eval");
    if self.raw {
      cmd.arg("--raw");
    }
    if self.impure {
      cmd.arg("--impure");
    }
    if self.with_nom {
      cmd.args(["--log-format", "internal-json", "-v"]);
    }
    if let Some(expr) = &self.expr {
      cmd.arg("--expr").arg(expr);
    }
    cmd
  }

  pub fn run_and_capture_stdout(self) -> Result<String> {
    run_nix_command(self.build_command(), self.with_nom, "nix eval", None, true)
  }
}

impl Default for EvalCommand {
  fn default() -> Self {
    Self::new()
  }
}

/// A builder for executing `nix build` commands.
///
/// This builder provides a fluent API for constructing and running `nix build` commands,
/// with integrated support for `nom` for pretty-printing build logs.
pub struct BuildCommand {
  installables: Vec<String>,
  expr: Option<String>,
  arg: HashMap<String, String>,
  argstr: HashMap<String, String>,
  out_link: Option<String>,
  no_link: bool,
  print_out_paths: bool,
  impure: bool,
  with_nom: bool,
  extra_args: Vec<String>,
}

impl BuildCommand {
  /// Creates a new `BuildCommand` with default settings.
  pub fn new() -> Self {
    Self {
      installables: Vec::new(),
      expr: None,
      arg: HashMap::new(),
      argstr: HashMap::new(),
      out_link: None,
      no_link: false,
      print_out_paths: false,
      impure: false,
      with_nom: interactive::current_settings().enabled(),
      extra_args: Vec::new(),
    }
  }

  /// Adds an installable (e.g., a flake attribute) to the build.
  pub fn installable(mut self, installable: &str) -> Self {
    self.installables.push(installable.to_string());
    self
  }

  /// Sets a Nix expression to be built via `--expr`.
  pub fn expr(mut self, expr: &str) -> Self {
    self.expr = Some(expr.to_string());
    self
  }

  /// Adds a nix expression argument via `--arg`.
  pub fn arg(mut self, key: &str, value: &str) -> Self {
    self.arg.insert(key.to_string(), value.to_string());
    self
  }

  /// Adds a string argument via `--argstr`.
  pub fn argstr(mut self, key: &str, value: &str) -> Self {
    self.argstr.insert(key.to_string(), value.to_string());
    self
  }

  /// Sets the output link path via `--out-link`.
  /// This conflicts with `no_link`.
  pub fn out_link(mut self, path: &str) -> Self {
    self.out_link = Some(path.to_string());
    self.no_link = false;
    self
  }

  /// Disables the creation of the `result` symlink via `--no-link`.
  /// This conflicts with `out_link`.
  pub fn no_link(mut self, no_link: bool) -> Self {
    self.no_link = no_link;
    if no_link {
      self.out_link = None;
    }
    self
  }

  /// Enables printing of the output store paths via `--print-out-paths`.
  pub fn print_out_paths(mut self, print: bool) -> Self {
    self.print_out_paths = print;
    self
  }

  /// Adds the `--impure` flag to allow access to mutable paths.
  pub fn impure(mut self, impure: bool) -> Self {
    self.impure = impure;
    self
  }

  /// Toggles the use of `nom` for log formatting.
  /// If true, adds `--log-format internal-json -v` and pipes stderr to `nom`.
  /// If false, inherits stdout/stderr directly from `nix build`.
  pub fn with_nom(mut self, nom: bool) -> Self {
    self.with_nom = nom;
    self
  }

  /// Appends extra arguments to the `nix build` command.
  pub fn extra_args(mut self, args: &[String]) -> Self {
    self.extra_args.extend_from_slice(args);
    self
  }

  /// Constructs the `std::process::Command` for `nix build`.
  fn build_command(&self) -> Command {
    let mut cmd = Command::new("nix");
    cmd.arg("build");

    for installable in &self.installables {
      cmd.arg(installable);
    }

    if let Some(expr) = &self.expr {
      cmd.arg("--expr").arg(expr);
    }

    for (key, value) in &self.arg {
      cmd.arg("--arg").arg(key).arg(value);
    }

    for (key, value) in &self.argstr {
      cmd.arg("--argstr").arg(key).arg(value);
    }

    if let Some(out_link) = &self.out_link {
      cmd.arg("--out-link").arg(out_link);
    }

    if self.no_link {
      cmd.arg("--no-link");
    }

    if self.print_out_paths {
      cmd.arg("--print-out-paths");
    }

    if self.impure {
      cmd.arg("--impure");
    }

    if self.with_nom {
      cmd.args(["--log-format", "internal-json", "-v"]);
    }

    cmd.args(&self.extra_args);

    cmd
  }

  /// Executes the configured `nix build` command.
  /// This method is suitable when stdout does not need to be captured.
  pub fn run(self) -> Result<()> {
    run_nix_command(
      self.build_command(),
      self.with_nom,
      "nix build",
      None,
      false,
    )
    .map(|_| ())
  }

  /// Executes the command and captures its standard output.
  /// This requires `print_out_paths` to be true to be useful.
  pub fn run_and_capture_stdout(self) -> Result<String> {
    run_nix_command(self.build_command(), self.with_nom, "nix build", None, true)
  }
}

impl Default for BuildCommand {
  fn default() -> Self {
    Self::new()
  }
}

fn run_nix_command(
  mut command: Command,
  with_nom: bool,
  label: &str,
  progress: Option<&ProblemProgressHandle>,
  capture_stdout: bool,
) -> Result<String> {
  if with_nom {
    interactive::suspend_live_render();
    let mut child = command
      .stdin(Stdio::null())
      .stdout(if capture_stdout {
        Stdio::piped()
      } else {
        Stdio::null()
      })
      .stderr(Stdio::piped())
      .spawn()
      .with_context(|| format!("Failed to spawn `{label}` process"))?;

    let stderr = child
      .stderr
      .take()
      .with_context(|| format!("Failed to capture stderr from {label} process"))?;

    let nom_status = Command::new("nom")
      .arg("--json")
      .stdin(stderr)
      .stdout(Stdio::inherit())
      .stderr(Stdio::inherit())
      .status()
      .context("Failed to execute `nom` log process")?;

    let output = if capture_stdout {
      Some(
        child
          .wait_with_output()
          .with_context(|| format!("Failed to wait for `{label}` process"))?,
      )
    } else {
      let status = child
        .wait()
        .with_context(|| format!("Failed to wait for `{label}` process"))?;
      if !status.success() {
        bail!("{label} command failed.");
      }
      None
    };

    if !nom_status.success() {
      interactive::resume_live_render(true);
      bail!("Log process `nom` failed with exit code: {:?}", nom_status);
    }

    if let Some(output) = output {
      if !output.status.success() {
        interactive::resume_live_render(true);
        bail!("{label} command failed.");
      }
      let stdout = String::from_utf8(output.stdout)
        .with_context(|| format!("Failed to parse {label} stdout as UTF-8"))?;
      interactive::resume_live_render(true);
      Ok(stdout.trim().to_string())
    } else {
      interactive::resume_live_render(true);
      Ok(String::new())
    }
  } else {
    if let Some(progress) = progress {
      progress.println_fallback(&format!("Running {label}..."));
    } else {
      interactive::log_line(&format!("Running {label}..."));
    }
    if capture_stdout {
      let output = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .with_context(|| format!("Failed to execute `{label}`"))?
        .wait_with_output()
        .with_context(|| format!("Failed to wait for `{label}`"))?;

      if !output.status.success() {
        bail!("{label} command failed.");
      }

      let stdout = String::from_utf8(output.stdout)
        .with_context(|| format!("Failed to parse {label} stdout as UTF-8"))?;
      Ok(stdout.trim().to_string())
    } else {
      let status = command
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .with_context(|| format!("Failed to execute `{label}`"))?;

      if !status.success() {
        bail!("{label} command failed.");
      }

      Ok(String::new())
    }
  }
}
