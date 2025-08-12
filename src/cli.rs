use clap::{Parser, Subcommand, command};

use crate::cmd::{compile_cwasm::CompileCwasmOpts, run_wasm::RunWasmOpts};

/// Competitive programming proposition automation tool
#[derive(Parser)]
#[command(
    name = "Hull",
    bin_name = "hull",
    author = "aberter0x3f <aberter0x3f@disroot.org>",
    version = env!("CARGO_PKG_VERSION"),
    max_term_width = 100,
)]
pub struct Opts {
  #[command(subcommand)]
  pub command: Command,
}

#[derive(Subcommand)]
pub enum Command {
  CompileCwasm(CompileCwasmOpts),
  RunWasm(RunWasmOpts),
}
