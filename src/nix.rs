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

use anyhow::{Context, Ok, Result, bail};
use serde::Deserialize;

#[derive(Deserialize)]
pub struct FlakeMetadata {
  url: String,
}

/// Get the current OS name in nix.
pub fn get_current_system() -> Result<String> {
  let output = Command::new("nix")
    .args(&["eval", "--raw", "nixpkgs#system"])
    .output()?;

  let data = String::from_utf8_lossy(&output.stdout);
  Ok(data.trim().to_string())
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
      with_nom: true, // Default to using nom for better logs
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
    let mut nix_build_cmd = self.build_command();

    if self.with_nom {
      let mut nix_build_process = nix_build_cmd
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .context("Failed to spawn `nix build` process")?;

      let nix_stderr = nix_build_process
        .stderr
        .take()
        .context("Failed to capture stderr from nix build process")?;

      let nom_status = Command::new("nom")
        .arg("--json")
        .stdin(nix_stderr)
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .context("Failed to execute `nom` log process")?;

      let nix_status = nix_build_process
        .wait()
        .context("Failed to wait for `nix build` process")?;

      if !nix_status.success() {
        bail!("Nix build command failed.");
      }
      if !nom_status.success() {
        bail!("Log process `nom` failed with exit code: {:?}", nom_status);
      }
    } else {
      let status = nix_build_cmd
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .context("Failed to execute `nix build`")?;

      if !status.success() {
        bail!("Nix build command failed.");
      }
    }

    Ok(())
  }

  /// Executes the command and captures its standard output.
  /// This requires `print_out_paths` to be true to be useful.
  pub fn run_and_capture_stdout(self) -> Result<String> {
    let mut nix_build_cmd = self.build_command();

    if self.with_nom {
      let mut nix_build_process = nix_build_cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("Failed to spawn `nix build` process")?;

      let nix_stderr = nix_build_process
        .stderr
        .take()
        .context("Failed to capture stderr from nix build process")?;

      let mut nom_process = Command::new("nom")
        .arg("--json")
        .stdin(nix_stderr)
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()
        .context("Failed to spawn `nom` log process")?;

      let output = nix_build_process
        .wait_with_output()
        .context("Failed to wait for `nix build` process")?;

      let nom_status = nom_process
        .wait()
        .context("Failed to wait for `nom` log process")?;

      if !nom_status.success() {
        bail!("Log process `nom` failed with exit code: {:?}", nom_status);
      }

      if !output.status.success() {
        bail!("Nix build command failed.");
      }

      let stdout_str =
        String::from_utf8(output.stdout).context("Failed to parse nix build stdout as UTF-8")?;
      Ok(stdout_str.trim().to_string())
    } else {
      let output = nix_build_cmd
        .stdin(Stdio::null())
        .output()
        .context("Failed to execute `nix build`")?;

      if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!("Nix build command failed. Stderr:\n{}", stderr.trim());
      }

      let stdout_str =
        String::from_utf8(output.stdout).context("Failed to parse nix build stdout as UTF-8")?;
      Ok(stdout_str.trim().to_string())
    }
  }
}
