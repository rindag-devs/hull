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

/// Formats a tick counter for terminal output.
pub fn format_tick(tick: u64) -> String {
  const THRESHOLD: u64 = 100_000;

  if tick < THRESHOLD {
    tick.to_string()
  } else {
    format!("{:.3e}", tick as f64)
  }
}

/// Formats a byte count into a human-readable IEC unit string.
pub fn format_size(byte: u64) -> String {
  const KIB: u64 = 1024;
  const MIB: u64 = 1024 * KIB;
  const GIB: u64 = 1024 * MIB;
  const TIB: u64 = 1024 * GIB;

  if byte <= KIB {
    format!("{} bytes", byte)
  } else if byte <= MIB {
    let kib_value = byte as f64 / KIB as f64;
    format!("{:.3} KiB", kib_value)
  } else if byte <= GIB {
    let mib_value = byte as f64 / MIB as f64;
    format!("{:.3} MiB", mib_value)
  } else if byte <= TIB {
    let gib_value = byte as f64 / GIB as f64;
    format!("{:.3} GiB", gib_value)
  } else {
    let tib_value = byte as f64 / TIB as f64;
    format!("{:.3} TiB", tib_value)
  }
}

/// Formats a duration in milliseconds or seconds for terminal output.
pub fn format_duration_ms(duration: std::time::Duration) -> String {
  let millis = duration.as_millis();
  if millis < 1_000 {
    format!("{millis} ms")
  } else {
    format!("{:.3} s", duration.as_secs_f64())
  }
}

/// Converts an underscore_case status name into a human-readable title.
pub fn to_title_case(s: &str) -> String {
  s.split('_')
    .map(|word| {
      let mut chars = word.chars();
      match chars.next() {
        None => String::new(),
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
      }
    })
    .collect::<Vec<_>>()
    .join(" ")
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn format_tick_uses_scientific_notation_above_threshold() {
    assert_eq!(format_tick(0), "0");
    assert_eq!(format_tick(99_999), "99999");
    assert_eq!(format_tick(12345), "12345");
    assert_eq!(format_tick(100_000), "1.000e5");
    assert_eq!(format_tick(123_456), "1.235e5");
    assert_eq!(format_tick(999_999), "1.000e6");
    assert_eq!(format_tick(1_000_000), "1.000e6");
    assert_eq!(format_tick(5_432_109), "5.432e6");
  }

  #[test]
  fn format_size_uses_iec_units() {
    const KIB: u64 = 1024;
    const MIB: u64 = 1024 * KIB;
    const GIB: u64 = 1024 * MIB;
    const TIB: u64 = 1024 * GIB;

    assert_eq!(format_size(0), "0 bytes");
    assert_eq!(format_size(1), "1 bytes");
    assert_eq!(format_size(512), "512 bytes");
    assert_eq!(format_size(1024), "1024 bytes");
    assert_eq!(format_size(KIB + 1), "1.001 KiB");
    assert_eq!(format_size(1536), "1.500 KiB");
    assert_eq!(format_size(100 * KIB), "100.000 KiB");
    assert_eq!(format_size(MIB), "1024.000 KiB");
    assert_eq!(format_size(MIB + 1), "1.000 MiB");
    assert_eq!(format_size(MIB + MIB / 2), "1.500 MiB");
    assert_eq!(format_size(256 * MIB), "256.000 MiB");
    assert_eq!(format_size(GIB), "1024.000 MiB");
    assert_eq!(format_size(GIB + 1), "1.000 GiB");
    assert_eq!(format_size(GIB + GIB / 4), "1.250 GiB");
    assert_eq!(format_size(500 * GIB), "500.000 GiB");
    assert_eq!(format_size(TIB), "1024.000 GiB");
    assert_eq!(format_size(TIB + 1), "1.000 TiB");
    assert_eq!(format_size(TIB + TIB / 2), "1.500 TiB");
    assert_eq!(format_size(123 * TIB), "123.000 TiB");
  }
}
