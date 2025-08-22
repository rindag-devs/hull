use anyhow::{Context, Result, bail};
use clap::Parser;
use std::process::{Command, Stdio};
use tracing::info;

#[derive(Parser)]
pub struct BuildOpts {
  /// The problem to build, e.g., "aPlusB".
  #[arg(long, short, default_value = "default")]
  problem: String,

  /// The target to build, e.g., "default".
  #[arg(long, short, default_value = "default")]
  target: String,

  /// The system to build, e.g., "x86_64-linux".
  #[arg(long)]
  system: Option<String>,

  /// Path to save the result link.
  #[arg(long, short, default_value = "result")]
  out_link: String,

  /// Whether to let nix resolve git submodules.
  #[arg(long)]
  submodules: bool,

  /// Extra arguments passed to nix build.
  #[arg(trailing_var_arg = true)]
  extra_args: Vec<String>,
}

fn get_current_system() -> Result<String> {
  let output = Command::new("nix")
    .args(&["eval", "--raw", "nixpkgs#system"])
    .output()?;

  let data = String::from_utf8_lossy(&output.stdout);
  Ok(data.trim().to_string())
}

pub fn run(build_opts: &BuildOpts) -> Result<()> {
  let system = build_opts.system.clone().unwrap_or(
    get_current_system().context("Failed to determine current system using `nix eval`")?,
  );

  let submodule_arg = if build_opts.submodules {
    "?submodules=1"
  } else {
    ""
  };

  let flake_attr = format!(
    ".{}#hullProblems.{}.{}.config.targetOutputs.{}",
    submodule_arg, system, build_opts.problem, build_opts.target
  );

  info!("Building target: {}", flake_attr);

  let nix_build = Command::new("nix")
    .args([
      "build",
      &flake_attr,
      "--out-link",
      &build_opts.out_link,
      "--log-format",
      "internal-json",
      "-v",
    ])
    .args(&build_opts.extra_args)
    .stdin(Stdio::null())
    .stdout(Stdio::null())
    .stderr(Stdio::piped())
    .spawn()?;

  let exit_status = Command::new("nom")
    .arg("--json")
    .stdin(nix_build.stderr.unwrap())
    .stdout(Stdio::inherit())
    .stderr(Stdio::inherit())
    .status()?;

  if !exit_status.success() {
    bail!("Build failed with exit code: {:?}", exit_status);
  }

  Ok(())
}
