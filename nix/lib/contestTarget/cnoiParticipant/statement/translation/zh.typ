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

#let input-format = "输入格式"
#let output-format = "输出格式"
#let traits = "特征"
#let subtasks = "子任务"
#let samples = "样例"
#let tick-limit = "时刻限制"
#let time-limit = "时间限制"
#let memory-limit = "内存限制"
#let score = "分数"
#let notes = "说明"
#let problem-name = "题目名称"
#let directory = "目录"
#let full-score = "满分"
#let compile-arguments = "编译选项"
#let source-program-file-name = "源程序文件名"
#let for-0-language(x) = "对于 " + x + " 语言"
#let sample-0-input(x) = "样例 " + str(x) + " 输入"
#let sample-0-output(x) = "样例 " + str(x) + " 输出"
#let sample-0-output-1(x, y) = [样例 #str(x) #y]
#let sample-0-description(x) = "样例 " + str(x) + " 描述"
#let sample-0-graph-visualization(x) = "样例 " + str(x) + " 图可视化"

#let ticks(n) = {
  if n < 100000 {
    [$#n$ 刻]
  } else {
    let exponent = calc.floor(calc.log(n, base: 10))
    let mantissa = n / calc.pow(10, exponent)
    let rounded_mantissa = calc.round(mantissa, digits: 3)
    let mantissa_str = str(rounded_mantissa)
    [$#mantissa_str times 10^#exponent$ 刻]
  }
}

#let milliseconds(n) = {
  if n <= 1000 {
    [$#n$ 毫秒]
  } else {
    [$#(n / 1000)$ 秒]
  }
}

#let bytes(n) = {
  let KiB = 1024.0
  let MiB = KiB * 1024
  let GiB = MiB * 1024
  let TiB = GiB * 1024

  if n <= KiB {
    $#n$ + " 字节"
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
  1. 文件名（程序名和输入输出文件名）必须使用英文小写．赛后正式测试时将以选手留在题目目录下的源代码为准．
  2. `main` 函数的返回值类型必须是 `int`，程序正常结束时的返回值必须是 `0`．
  3. 若无特殊说明，结果的比较方式为全文比较（过滤行末空格及文末换行）．
  4. 选手提交的程序源文件大小不得超过 100 KiB．
  5. 程序可使用的栈空间内存限制与题目的内存限制一致．
  6. 禁止在源代码中改变编译器参数（如使用 `#pragma` 命令），禁止使用系统结构相关指令（如内联汇编）或其他可能造成不公平的方法．
  7. 因违反上述规定而出现的问题，申诉时一律不予受理．
]
