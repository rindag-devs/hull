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

#let format-size(num) = {
  let rounded = calc.round(num, digits: 3)
  let s = repr(rounded)
  if s.contains(".") {
    s = s.trim("0").trim(".")
  }
  s
}

#let input-format = "input format"
#let output-format = "output format"
#let traits = "traits"
#let subtasks = "subtasks"
#let samples = "samples"
#let tick-limit = "tick limit"
#let time-limit = "time limit"
#let memory-limit = "memory limit"
#let score = "score"
#let notes = "notes"
#let problem-name = "problem name"
#let directory = "directory"
#let full-score = "full score"
#let compile-arguments = "compile arguments"
#let source-program-file-name = "source code file name"
#let for-0-language(x) = "for " + x + " language"
#let sample-0-input(x) = "sample " + str(x) + " input"
#let sample-0-output(x) = "sample " + str(x) + " output"
#let sample-0-output-1(x, y) = [sample #str(x) #y]

#let ticks(n) = {
  if n < 100000 {
    [$#n$ ticks]
  } else {
    let exponent = calc.floor(calc.log(n, base: 10))
    let mantissa = n / calc.pow(10, exponent)
    let rounded_mantissa = calc.round(mantissa, digits: 3)
    let mantissa_str = str(rounded_mantissa)
    [$#mantissa_str times 10^#exponent$ ticks]
  }
}

#let milliseconds(n) = {
  if n <= 1000 {
    [$#n$ ms]
  } else {
    [$#(n / 1000)$ s]
  }
}

#let bytes(n) = {
  let KiB = 1024.0
  let MiB = KiB * 1024
  let GiB = MiB * 1024
  let TiB = GiB * 1024

  if n <= KiB {
    $#n$ + " bytes"
  } else if n <= MiB {
    $#format-size(n / KiB)$ + " KiB"
  } else if n <= GiB {
    $#format-size(n / MiB)$ + " MiB"
  } else if n <= TiB {
    $#format-size(n / GiB)$ + " GiB"
  } else {
    $#format-size(n / TiB)$ + " TiB"
  }
}

#let contest-notes-body = [
  1. File names (including program, input, and output files) must be in lowercase English. The official evaluation after the contest will be based on the source code file(s) left by the contestant in the problem directory.
  2. The return type of the `main` function must be `int`. The program must return `0` upon normal termination.
  3. Unless otherwise specified, outputs will be judged by an exact match comparison, ignoring trailing whitespace at the end of each line and trailing newlines at the end of the file.
  4. The size of the submitted source code file must not exceed 100 KiB.
  5. The stack space available to the program is included within the overall memory limit specified for the problem.
  6. It is prohibited to modify compiler parameters within the source code (e.g., using `#pragma` directives), use system architecture-specific instructions (e.g., inline assembly), or employ any other methods that could create an unfair advantage.
  7. Appeals regarding issues caused by violations of the above rules will not be accepted.
]
