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
use clap::Subcommand;

/// CNOI participant bundle integration.
pub mod cnoi;
/// Hydro bundle integration.
pub mod hydro;
/// Lemon bundle integration.
pub mod lemon;
/// UOJ bundle integration.
pub mod uoj;

/// Hidden judge-system integration helper subcommands.
#[derive(Subcommand)]
pub enum IntegrationJudgeCommand {
  /// Judge participant samples from a CNOI participant bundle.
  Cnoi(cnoi::CnoiOpts),
  /// Judge one bundled Hydro submission through Hull's scheduler.
  Hydro(hydro::HydroOpts),
  /// Judge one bundled Lemon submission through Hull's scheduler.
  Lemon(lemon::LemonOpts),
  /// Judge one bundled UOJ submission through Hull's scheduler.
  Uoj(uoj::UojOpts),
}

/// Runs a judge-system integration helper subcommand.
pub fn run(command: &IntegrationJudgeCommand) -> Result<()> {
  match command {
    IntegrationJudgeCommand::Cnoi(opts) => cnoi::run(opts),
    IntegrationJudgeCommand::Hydro(opts) => hydro::run(opts),
    IntegrationJudgeCommand::Lemon(opts) => lemon::run(opts),
    IntegrationJudgeCommand::Uoj(opts) => uoj::run(opts),
  }
}
