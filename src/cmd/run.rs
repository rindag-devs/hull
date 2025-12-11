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

use std::{fs, path::Path};

use anyhow::{Context, Result};
use cap_std::{ambient_authority, fs::Dir};
use clap::Parser;
use tracing::info;
use wasi_common::{
  WasiDir, WasiFile,
  pipe::{ReadPipe, WritePipe},
  sync::dir::Dir as WasiSyncDir,
};

use crate::{
  nix::{BuildCommand, get_current_system, get_flake_url},
  runner,
};

#[derive(Parser)]
pub struct RunOpts {
  /// The problem context to use for compilation.
  #[arg(long, short, default_value = "default")]
  problem: String,

  /// The language name (e.g., "cpp.20"). Auto-detected if not provided.
  #[arg(long, short)]
  language: Option<String>,

  /// Override the tick limit for this run.
  #[arg(long, short)]
  tick_limit: Option<u64>,

  /// Override the memory limit (in bytes) for this run.
  #[arg(long, short)]
  memory_limit: Option<u64>,

  /// Show a report of the execution status (tick, memory, etc.) on stderr.
  #[arg(long)]
  show_status: bool,

  /// Whether to let nix resolve git submodules.
  #[arg(long)]
  submodules: bool,

  /// Path to the source file to run.
  src_path: String,

  /// Arguments to pass to the executed program.
  #[arg(trailing_var_arg = true)]
  args: Vec<String>,
}

pub fn run(opts: &RunOpts) -> Result<()> {
  // Get absolute path of source file
  let src_path_abs = Path::new(&opts.src_path)
    .canonicalize()
    .with_context(|| format!("Failed to find source file: {}", opts.src_path))?;
  let src_path_str = src_path_abs.to_str().with_context(|| {
    format!(
      "Path '{}' contains non-UTF-8 characters and cannot be processed.",
      src_path_abs.display()
    )
  })?;

  // Construct and run nix build command
  let system =
    get_current_system().context("Failed to determine current system using `nix eval`")?;
  let flake_url =
    get_flake_url().context("Could not determine the flake URL for the current project")?;
  let submodule_query = if opts.submodules { "?submodules=1" } else { "" };
  let final_flake_ref = format!("{}{}", flake_url, submodule_query);

  info!("Compiling source file: {}", opts.src_path);

  let problem_name = &opts.problem;

  let nix_expr = format!(
    r#"
      {{ srcPath, languageName }}:
      let
        flake = builtins.getFlake "{final_flake_ref}";
        hullLib = (flake.inputs.hull.lib or flake.outputs.lib).{system};
        pkgs = flake.inputs.nixpkgs.legacyPackages.{system};
        problem = flake.outputs.hullProblems.{system}.{problem_name}.config;

        langName = if languageName != null
                  then languageName
                  else hullLib.language.matchBaseName (builtins.baseNameOf srcPath) problem.languages;

        _ = if langName == null then throw "Could not determine language for file: ${{srcPath}}" else null;
        lang = problem.languages.${{langName}} or (throw "Language '" + langName + "' not found for problem '{problem_name}'");

        wasm = lang.compile.executable {{
          name = "hull-run-${{builtins.baseNameOf srcPath}}";
          src = (/. + srcPath);
          includes = problem.includes;
          extraObjects = [];
        }};
      in
      wasm
    "#
  );

  let mut build_cmd = BuildCommand::new()
    .impure(true) // For srcPath
    .expr(&nix_expr)
    .argstr("srcPath", src_path_str)
    .argstr("problemName", &opts.problem);

  build_cmd = match &opts.language {
    Some(lang) => build_cmd.argstr("languageName", lang),
    None => build_cmd.arg("languageName", "null"),
  };

  let wasm_path = build_cmd
    .print_out_paths(true)
    .no_link(true)
    .run_and_capture_stdout()
    .context("Failed to execute `nix build` for compilation")?;

  info!("Precompiling program");
  let wasm_bytes = fs::read(&wasm_path)
    .with_context(|| format!("Failed to read compiled WASM from {}", &wasm_path))?;

  let cwasm_bytes = runner::compile(&wasm_bytes)?;

  let stdin: Box<dyn WasiFile> = Box::new(ReadPipe::new(std::io::stdin()));
  let stdout: Box<dyn WasiFile> = Box::new(WritePipe::new(std::io::stdout()));
  let stderr: Box<dyn WasiFile> = Box::new(WritePipe::new(std::io::stderr()));

  // Grant real file system access by pre-opening the root directory.
  let dir = Dir::open_ambient_dir("/", ambient_authority())
    .context("Failed to open host root directory '/' for WASI preopen")?;
  let preopened_dir: Option<Box<dyn WasiDir>> = Some(Box::new(WasiSyncDir::from_cap_std(dir)));

  info!("Running program");
  let result = runner::run(
    &cwasm_bytes,
    &opts.args,
    opts.tick_limit.unwrap_or(10u64.pow(18)),
    opts.memory_limit.unwrap_or(u32::MAX as u64),
    [stdin, stdout, stderr],
    preopened_dir,
  );

  // Show status if requested
  if opts.show_status {
    use crate::utils::{format_size, format_tick};
    eprintln!("Status: {:?}", result.status);
    eprintln!("Exit code: {}", result.exit_code);
    eprintln!("Tick: {}", format_tick(result.tick));
    eprintln!("Memory: {}", format_size(result.memory));
    if !result.error_message.is_empty() {
      eprintln!("Error message:\n{}", result.error_message);
    }
  }

  Ok(())
}
