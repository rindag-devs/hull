mod archive;
mod config;
mod files;
mod process;
mod result;
mod supervisor;

use config::Args;
use process::SignalMonitor;
use supervisor::Supervisor;

const USAGE: &str = "usage: hull-uoj-supervisor <main_path> <work_path> <result_path> <data_path>";

fn main() {
  let signals = match SignalMonitor::new() {
    Ok(signals) => signals,
    Err(error) => {
      eprintln!("hull-uoj-supervisor: failed to monitor signals: {error}");
      std::process::exit(1);
    }
  };
  let args = match Args::parse(std::env::args_os()) {
    Ok(args) => args,
    Err(error) => {
      eprintln!("hull-uoj-supervisor: {error}\n{USAGE}");
      std::process::exit(1);
    }
  };
  if let Err(error) = Supervisor::new(args, signals).run() {
    eprintln!("hull-uoj-supervisor: {error}");
    std::process::exit(error.exit_code());
  }
}
