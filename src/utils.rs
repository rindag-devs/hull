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

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn test_format_tick() {
    // Below threshold
    assert_eq!(format_tick(0), "0");
    assert_eq!(format_tick(99_999), "99999");
    assert_eq!(format_tick(12345), "12345");

    // At and above threshold (scientific notation)
    assert_eq!(format_tick(100_000), "1.000e5");
    assert_eq!(format_tick(123_456), "1.235e5"); // checks rounding
    assert_eq!(format_tick(999_999), "1.000e6");
    assert_eq!(format_tick(1_000_000), "1.000e6");
    assert_eq!(format_tick(5_432_109), "5.432e6"); // checks rounding
  }

  #[test]
  fn test_format_size() {
    // Define constants for clarity in tests
    const KIB: u64 = 1024;
    const MIB: u64 = 1024 * KIB;
    const GIB: u64 = 1024 * MIB;
    const TIB: u64 = 1024 * GIB;

    // --- Test Bytes ---
    assert_eq!(format_size(0), "0 bytes");
    assert_eq!(format_size(1), "1 bytes");
    assert_eq!(format_size(512), "512 bytes");
    // Test the upper boundary for bytes
    assert_eq!(format_size(1024), "1024 bytes");

    // --- Test KiB ---
    // Test just over the KiB boundary (shows rounding)
    assert_eq!(format_size(KIB + 1), "1.001 KiB");
    // Test a typical KiB value
    assert_eq!(format_size(1536), "1.500 KiB");
    // Test a larger KiB value
    assert_eq!(format_size(100 * KIB), "100.000 KiB");
    // Test the upper boundary for KiB
    assert_eq!(format_size(MIB), "1024.000 KiB");

    // --- Test MiB ---
    // Test just over the MiB boundary (shows rounding)
    assert_eq!(format_size(MIB + 1), "1.000 MiB");
    // Test a typical MiB value
    assert_eq!(format_size(MIB + MIB / 2), "1.500 MiB");
    // Test a larger MiB value
    assert_eq!(format_size(256 * MIB), "256.000 MiB");
    // Test the upper boundary for MiB
    assert_eq!(format_size(GIB), "1024.000 MiB");

    // --- Test GiB ---
    // Test just over the GiB boundary
    assert_eq!(format_size(GIB + 1), "1.000 GiB");
    // Test a typical GiB value
    assert_eq!(format_size(GIB + GIB / 4), "1.250 GiB");
    // Test a larger GiB value
    assert_eq!(format_size(500 * GIB), "500.000 GiB");
    // Test the upper boundary for GiB
    assert_eq!(format_size(TIB), "1024.000 GiB");

    // --- Test TiB ---
    // Test just over the TiB boundary
    assert_eq!(format_size(TIB + 1), "1.000 TiB");
    // Test a typical TiB value
    assert_eq!(format_size(TIB + TIB / 2), "1.500 TiB");
    // Test a very large value
    assert_eq!(format_size(123 * TIB), "123.000 TiB");
  }
}
