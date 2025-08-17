#let format-size(num) = {
  let rounded = calc.round(num, digits: 3)
  let s = repr(rounded)
  if s.contains(".") {
    s = s.trim("0").trim(".")
  }
  s
}

#let input = "input"
#let output = "output"
#let traits = "traits"
#let subtasks = "subtasks"
#let samples = "samples"
#let tick_limit = "tick limit"
#let memory_limit = "memory limit"

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

#let bytes(n) = {
  let KiB = 1024.0
  let MiB = KiB * 1024
  let GiB = MiB * 1024
  let TiB = GiB * 1024

  if n <= KiB {
    $#n$ + " Bytes"
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
