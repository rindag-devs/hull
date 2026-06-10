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
use std::ffi::OsString;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result, anyhow, bail};
use serde::Deserialize;

use crate::interactive;

enum ExprInput {
  Arg(String),
  File(PathBuf),
  Stdin(String),
}

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
    bail!("Failed to get flake metadata.\nStderr:\n{}", stderr.trim());
  }

  let metadata_str = String::from_utf8(output.stdout)
    .context("Failed to parse `nix flake metadata` output as UTF-8")?;

  let metadata: FlakeMetadata = serde_json::from_str(&metadata_str)
    .context("Failed to parse JSON from `nix flake metadata`")?;

  Ok(metadata.url)
}

pub struct EvalCommand {
  expr: Option<ExprInput>,
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
      // `nix eval` for metadata loading should stay quiet. Enabling verbose
      // internal-json logs here can flood `nom` with evaluation trace output
      // and make lightweight metadata queries appear to hang.
      with_nom: false,
    }
  }

  pub fn expr(mut self, expr: &str) -> Self {
    self.expr = Some(ExprInput::Arg(expr.to_string()));
    self
  }

  pub fn expr_file(mut self, path: PathBuf) -> Self {
    self.expr = Some(ExprInput::File(path));
    self
  }

  pub fn expr_stdin(mut self, expr: &str) -> Self {
    self.expr = Some(ExprInput::Stdin(expr.to_string()));
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
      match expr {
        ExprInput::Arg(expr) => {
          cmd.arg("--expr").arg(expr);
        }
        ExprInput::File(expr_file) => {
          cmd.arg("--file").arg(expr_file);
        }
        ExprInput::Stdin(_) => {
          cmd.arg("--file").arg("-");
        }
      }
    }
    cmd
  }

  pub fn run_and_capture_stdout(self) -> Result<String> {
    let stdin_expr = match &self.expr {
      Some(ExprInput::Stdin(expr)) => Some(expr.clone()),
      _ => None,
    };
    run_nix_command(
      self.build_command(),
      self.with_nom,
      "nix eval",
      true,
      stdin_expr,
    )
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
  expr: Option<ExprInput>,
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
    self.expr = Some(ExprInput::Arg(expr.to_string()));
    self
  }

  pub fn expr_file(mut self, path: PathBuf) -> Self {
    self.expr = Some(ExprInput::File(path));
    self
  }

  pub fn expr_stdin(mut self, expr: &str) -> Self {
    self.expr = Some(ExprInput::Stdin(expr.to_string()));
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
      match expr {
        ExprInput::Arg(expr) => {
          cmd.arg("--expr").arg(expr);
        }
        ExprInput::File(expr_file) => {
          cmd.arg("--file").arg(expr_file);
        }
        ExprInput::Stdin(_) => {
          cmd.arg("--file").arg("-");
        }
      }
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

  /// Returns the executable and arguments that identify this build command.
  pub fn build_command_key(&self) -> Vec<OsString> {
    let command = self.build_command();
    std::iter::once(command.get_program().to_os_string())
      .chain(command.get_args().map(|arg| arg.to_os_string()))
      .collect()
  }

  /// Executes the configured `nix build` command.
  /// This method is suitable when stdout does not need to be captured.
  pub fn run(self) -> Result<()> {
    let stdin_expr = match &self.expr {
      Some(ExprInput::Stdin(expr)) => Some(expr.clone()),
      _ => None,
    };
    run_nix_command(
      self.build_command(),
      self.with_nom,
      "nix build",
      false,
      stdin_expr,
    )
    .map(|_| ())
  }

  /// Executes the command and captures its standard output.
  /// This requires `print_out_paths` to be true to be useful.
  pub fn run_and_capture_stdout(self) -> Result<String> {
    let stdin_expr = match &self.expr {
      Some(ExprInput::Stdin(expr)) => Some(expr.clone()),
      _ => None,
    };
    run_nix_command(
      self.build_command(),
      self.with_nom,
      "nix build",
      true,
      stdin_expr,
    )
  }
}

impl Default for BuildCommand {
  fn default() -> Self {
    Self::new()
  }
}

pub fn run_build_commands(commands: Vec<BuildCommand>, label: &str) -> Result<()> {
  if commands.is_empty() {
    return Ok(());
  }

  let with_nom = commands.iter().any(|command| command.with_nom);
  let _suspend = interactive::suspend_live_render();
  let mut nom_child = if with_nom {
    Some(
      Command::new("nom")
        .arg("--json")
        .stdin(Stdio::piped())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()
        .context("Failed to execute `nom` log process")?,
    )
  } else {
    None
  };
  let nom_stdin = nom_child
    .as_mut()
    .and_then(|child| child.stdin.take())
    .map(|stdin| Arc::new(Mutex::new(stdin)));
  let mut children = Vec::new();
  let mut log_threads = Vec::new();
  for command in commands {
    let mut command = command.build_command();
    match command
      .stdin(Stdio::null())
      .stdout(Stdio::inherit())
      .stderr(if with_nom {
        Stdio::piped()
      } else {
        Stdio::inherit()
      })
      .spawn()
    {
      Ok(mut child) => {
        if let Some(nom_stdin) = nom_stdin.clone() {
          let mut stderr = child
            .stderr
            .take()
            .with_context(|| format!("Failed to capture stderr from `{label}` process"))?;
          log_threads.push(std::thread::spawn(move || -> std::io::Result<()> {
            let mut buffer = [0; 8192];
            loop {
              let read = stderr.read(&mut buffer)?;
              if read == 0 {
                break;
              }
              let mut nom_stdin = nom_stdin
                .lock()
                .map_err(|_| std::io::Error::other("nom stdin lock poisoned"))?;
              nom_stdin.write_all(&buffer[..read])?;
            }
            Ok(())
          }));
        }
        children.push(child);
      }
      Err(err) => {
        for child in &mut children {
          let _ = child.kill();
          let _ = child.wait();
        }
        return Err(err).with_context(|| format!("Failed to spawn `{label}` process"));
      }
    }
  }

  let mut errors = Vec::new();
  for child in &mut children {
    let status = child
      .wait()
      .with_context(|| format!("Failed to wait for `{label}` process"))?;
    if !status.success() {
      errors.push(status.to_string());
    }
  }
  for thread in log_threads {
    thread
      .join()
      .map_err(|_| anyhow!("{label} log forwarding thread panicked"))?
      .with_context(|| format!("Failed to forward `{label}` logs to nom"))?;
  }
  drop(nom_stdin);
  if let Some(mut nom_child) = nom_child {
    let nom_status = nom_child
      .wait()
      .context("Failed to wait for `nom` log process")?;
    if !nom_status.success() {
      errors.push(format!("nom failed with {nom_status}"));
    }
  }
  if errors.is_empty() {
    Ok(())
  } else {
    bail!("{label} command failed: {}", errors.join(", "))
  }
}

fn run_nix_command(
  mut command: Command,
  with_nom: bool,
  label: &str,
  capture_stdout: bool,
  stdin_input: Option<String>,
) -> Result<String> {
  if with_nom {
    let _suspend = interactive::suspend_live_render();
    let mut child = command
      .stdin(if stdin_input.is_some() {
        Stdio::piped()
      } else {
        Stdio::null()
      })
      .stdout(if capture_stdout {
        Stdio::piped()
      } else {
        Stdio::null()
      })
      .stderr(Stdio::piped())
      .spawn()
      .with_context(|| format!("Failed to spawn `{label}` process"))?;

    write_child_stdin(&mut child, stdin_input, label)?;

    let stderr = child
      .stderr
      .take()
      .with_context(|| format!("Failed to capture stderr from {label} process"))?;

    let mut nom_child = Command::new("nom")
      .arg("--json")
      .stdin(stderr)
      .stdout(Stdio::inherit())
      .stderr(Stdio::inherit())
      .spawn()
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

    let nom_status = nom_child
      .wait()
      .context("Failed to wait for `nom` log process")?;

    if !nom_status.success() {
      bail!("Log process `nom` failed with exit code: {:?}", nom_status);
    }

    if let Some(output) = output {
      if !output.status.success() {
        bail!("{label} command failed.");
      }
      let stdout = String::from_utf8(output.stdout)
        .with_context(|| format!("Failed to parse {label} stdout as UTF-8"))?;
      Ok(stdout.trim().to_string())
    } else {
      Ok(String::new())
    }
  } else {
    interactive::log_line(&format!("Running {label}..."));
    let _suspend = interactive::suspend_live_render();
    let mut child = command
      .stdin(if stdin_input.is_some() {
        Stdio::piped()
      } else {
        Stdio::null()
      })
      .stdout(if capture_stdout {
        Stdio::piped()
      } else {
        Stdio::inherit()
      })
      .stderr(Stdio::inherit())
      .spawn()
      .with_context(|| format!("Failed to execute `{label}`"))?;

    write_child_stdin(&mut child, stdin_input, label)?;

    if capture_stdout {
      let output = child
        .wait_with_output()
        .with_context(|| format!("Failed to wait for `{label}`"))?;

      if !output.status.success() {
        bail!("{label} command failed.");
      }

      let stdout = String::from_utf8(output.stdout)
        .with_context(|| format!("Failed to parse {label} stdout as UTF-8"))?;
      Ok(stdout.trim().to_string())
    } else {
      let status = child
        .wait()
        .with_context(|| format!("Failed to execute `{label}`"))?;

      if !status.success() {
        bail!("{label} command failed.");
      }

      Ok(String::new())
    }
  }
}

fn write_child_stdin(
  child: &mut std::process::Child,
  stdin_input: Option<String>,
  label: &str,
) -> Result<()> {
  if let Some(stdin_input) = stdin_input {
    let mut stdin = child
      .stdin
      .take()
      .with_context(|| format!("Failed to open stdin for `{label}` process"))?;
    stdin
      .write_all(stdin_input.as_bytes())
      .with_context(|| format!("Failed to write stdin for `{label}` process"))?;
  }
  Ok(())
}
