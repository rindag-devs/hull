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

pub fn format_tick(tick: u64) -> String {
  const THRESHOLD: u64 = 100_000;

  if tick < THRESHOLD {
    tick.to_string()
  } else {
    format!("{:.3e}", tick as f64)
  }
}

pub fn format_size(byte: u64) -> String {
  const KIB: u64 = 1024;
  const MIB: u64 = 1024 * KIB;
  const GIB: u64 = 1024 * MIB;
  const TIB: u64 = 1024 * GIB;

  if byte < KIB {
    format!("{} bytes", byte)
  } else if byte < MIB {
    let kib_value = byte as f64 / KIB as f64;
    format!("{:.3} KiB", kib_value)
  } else if byte < GIB {
    let mib_value = byte as f64 / MIB as f64;
    format!("{:.3} MiB", mib_value)
  } else if byte < TIB {
    let gib_value = byte as f64 / GIB as f64;
    format!("{:.3} GiB", gib_value)
  } else {
    let tib_value = byte as f64 / TIB as f64;
    format!("{:.3} TiB", tib_value)
  }
}
