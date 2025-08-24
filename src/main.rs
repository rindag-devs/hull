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

use anyhow::Result;
use clap::Parser;
use cli::Opts;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

pub mod cli;
pub mod cmd;
pub mod nix;
pub mod runner;
pub mod utils;

fn main() -> Result<()> {
  tracing_subscriber::registry()
    .with(
      tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| format!("{}=debug", env!("CARGO_CRATE_NAME")).into()),
    )
    .with(tracing_subscriber::fmt::layer())
    .init();

  let opts = Opts::parse();

  match &opts.command {
    cli::Command::Build(build_opts) => cmd::build::run(build_opts),
    cli::Command::CompileCwasm(compile_cwasm_opts) => cmd::compile_cwasm::run(compile_cwasm_opts),
    cli::Command::Judge(judge_opts) => cmd::judge::run(judge_opts),
    cli::Command::RunWasm(run_wasm_opts) => cmd::run_wasm::run(run_wasm_opts),
    cli::Command::Stress(stress_opts) => cmd::stress::run(stress_opts),
  }
}
