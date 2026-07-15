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

use std::{
  fs::File,
  io::{self, Write},
  path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail};
use clap::{Args, Parser};
use tracing::info;

use crate::nix::{BuildCommand, get_flake_url};

/// Source compilation options shared by `compile` and `run`.
#[derive(Args)]
pub struct SourceCompileOpts {
  /// Problem name that provides languages and includes for compilation.
  #[arg(long, short, default_value = "default")]
  pub problem: String,

  /// Language name to compile with, e.g. `cpp.20`. Auto-detected if omitted.
  #[arg(long, short)]
  pub language: Option<String>,

  /// Let `nix` fetch flake inputs with Git submodules enabled.
  #[arg(long)]
  pub submodules: bool,

  /// Path to the source file to compile.
  pub src_path: String,
}

/// Options for compiling one source file to WebAssembly.
#[derive(Parser)]
pub struct CompileOpts {
  /// Source and problem options used for compilation.
  #[command(flatten)]
  pub source: SourceCompileOpts,

  /// Output path, or `-` to write the WASM module to stdout.
  #[arg(long, short)]
  pub output: Option<String>,
}

/// Compiles a source file and returns the realized WASM store path.
pub fn compile_source(opts: &SourceCompileOpts) -> Result<String> {
  let src_path_abs = Path::new(&opts.src_path)
    .canonicalize()
    .with_context(|| format!("Failed to find source file: {}", opts.src_path))?;
  let src_path_str = src_path_abs.to_str().with_context(|| {
    format!(
      "Path `{}` contains non-UTF-8 characters and cannot be processed.",
      src_path_abs.display()
    )
  })?;

  let flake_url =
    get_flake_url().context("Could not determine the flake URL for the current project")?;
  let submodule_query = if opts.submodules { "?submodules=1" } else { "" };
  let final_flake_ref = format!("{}{}", flake_url, submodule_query);
  let problem_name = &opts.problem;

  info!("Compiling source file: {}", opts.src_path);

  let nix_expr = format!(
    r#"
      {{ srcPath, languageName }}:
      let
        flake = builtins.getFlake "{final_flake_ref}";
        hullLib = (flake.inputs.hull.lib or flake.outputs.lib).${{builtins.currentSystem}};
        problem = flake.outputs.hullProblems.${{builtins.currentSystem}}.{problem_name}.config;

        wasm = hullLib.compile.executable.drv {{
          languages = problem.languages;
          name = "hull-compile-${{builtins.baseNameOf srcPath}}";
          src = (/. + srcPath);
          inherit languageName;
          includes = problem.includes;
          extraObjects = [];
        }};
      in
      wasm
    "#
  );
  let mut build_cmd = BuildCommand::new()
    .impure(true)
    .expr_stdin(&nix_expr)
    .argstr("srcPath", src_path_str);

  build_cmd = match &opts.language {
    Some(language) => build_cmd.argstr("languageName", language),
    None => build_cmd.arg("languageName", "null"),
  };

  build_cmd
    .print_out_paths(true)
    .no_link(true)
    .run_and_capture_stdout()
    .context("Failed to execute `nix build` for compilation")
}

fn default_output_path(src_path: &Path) -> Result<PathBuf> {
  let file_name = src_path
    .file_name()
    .and_then(|name| name.to_str())
    .with_context(|| {
      format!(
        "Source path `{}` has no valid UTF-8 file name",
        src_path.display()
      )
    })?;
  let stem = if let Some((prefix, _)) = file_name.rsplit_once('.') {
    prefix
      .rsplit_once('.')
      .filter(|(_, version)| version.chars().all(|c| c.is_ascii_digit()))
      .map_or(prefix, |(name, _)| name)
  } else {
    file_name
  };
  if stem.is_empty() {
    bail!("Cannot derive an output name from `{}`", src_path.display());
  }
  Ok(PathBuf::from(format!("{stem}.wasm")))
}

/// Compiles one source file and writes the resulting WASM module.
pub fn run(opts: &CompileOpts) -> Result<()> {
  let wasm_path = compile_source(&opts.source)?;
  let output = opts
    .output
    .as_deref()
    .map(PathBuf::from)
    .map_or_else(|| default_output_path(Path::new(&opts.source.src_path)), Ok)?;
  let mut wasm = File::open(&wasm_path)
    .with_context(|| format!("Failed to open compiled WASM module {wasm_path}"))?;

  if output == Path::new("-") {
    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    io::copy(&mut wasm, &mut stdout).context("Failed to write compiled WASM module to stdout")?;
    stdout
      .flush()
      .context("Failed to flush compiled WASM module to stdout")?;
  } else {
    let mut output_file = File::create(&output)
      .with_context(|| format!("Failed to create compiled WASM output {}", output.display()))?;
    io::copy(&mut wasm, &mut output_file).with_context(|| {
      format!(
        "Failed to write compiled WASM module to {}",
        output.display()
      )
    })?;
  }

  Ok(())
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn default_output() {
    assert_eq!(
      default_output_path(Path::new("path/to/foo.20.cpp")).unwrap(),
      Path::new("foo.wasm")
    );
    assert_eq!(
      default_output_path(Path::new("foo.bar.20.cpp")).unwrap(),
      Path::new("foo.bar.wasm")
    );
    assert_eq!(
      default_output_path(Path::new("foo.3.py")).unwrap(),
      Path::new("foo.wasm")
    );
    assert!(default_output_path(Path::new(".cpp")).is_err());
  }
}
