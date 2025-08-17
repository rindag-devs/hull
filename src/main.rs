use anyhow::Result;
use clap::Parser;
use cli::Opts;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

pub mod cli;
pub mod cmd;
pub mod runner;

#[tokio::main]
async fn main() -> Result<()> {
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
    cli::Command::RunWasm(run_wasm_opts) => cmd::run_wasm::run(run_wasm_opts),
  }
}
