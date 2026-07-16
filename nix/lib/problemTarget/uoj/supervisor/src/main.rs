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
