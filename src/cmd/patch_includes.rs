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

use anyhow::{Context, Result};
use clap::Parser;
use regex::bytes::Regex;
use std::{borrow::Cow, fs, str::Chars};
use tree_sitter::{Parser as TsParser, Query, QueryCursor, StreamingIterator};

/// Takes in a string with backslash escapes written out with literal backslash characters and
/// converts it to a string with the proper escaped characters.
fn unescape(input: &str) -> String {
  let mut chars = input.chars();
  let mut s = String::new();

  while let Some(c) = chars.next() {
    if c != '\\' {
      s.push(c);
      continue;
    }
    let Some(char) = chars.next() else {
      // This means that the last char is a `\\`
      assert_eq!(c, '\\');
      s.push('\\');
      break;
    };

    let escaped: Option<char> = match char {
      'n' => Some('\n'),
      'r' => Some('\r'),
      't' => Some('\t'),
      '\'' => Some('\''),
      '\"' => Some('\"'),
      '\\' => Some('\\'),
      'u' => escape_n_chars(&mut chars, 4),
      'x' => escape_n_chars(&mut chars, 2),
      _ => None,
    };
    if let Some(char) = escaped {
      // Successfully escaped a sequence
      s.push(char);
    } else {
      // User didn't meant to escape that
      s.push('\\');
      s.push(char);
    }
  }

  s
}

/// This is for sequences such as `\x08` or `\u1234`
fn escape_n_chars(chars: &mut Chars<'_>, length: usize) -> Option<char> {
  let s = chars.as_str().get(0..length)?;
  let u = u32::from_str_radix(&s, 16).ok()?;
  let ch = char::from_u32(u)?;
  _ = chars.nth(length);
  Some(ch)
}

struct Replacer {
  regex: Regex,
  replace_with: Vec<u8>,
}

impl Replacer {
  fn new(find: String, replace_with: String, flags: Option<String>) -> Result<Self> {
    let replace_with = unescape(&replace_with).into_bytes();

    let mut find_mut = find;

    if let Some(flags) = &flags
      && flags.contains('w')
    {
      find_mut = format!("\\b{}\\b", find_mut);
    }

    let mut regex_builder = regex::bytes::RegexBuilder::new(&find_mut);
    regex_builder.multi_line(true); // Default to multi-line

    if let Some(flags) = flags {
      for c in flags.chars() {
        match c {
          'c' => {
            regex_builder.case_insensitive(false);
          }
          'i' => {
            regex_builder.case_insensitive(true);
          }
          'm' => {
            regex_builder.multi_line(true);
          }
          'e' => {
            regex_builder.multi_line(false);
          }
          's' => {
            regex_builder.dot_matches_new_line(true);
          }
          'w' => {} // Already handled
          _ => {}   // Ignore unknown flags
        };
      }
    }

    let regex = regex_builder.build().context("Failed to build regex")?;

    Ok(Self {
      regex,
      replace_with,
    })
  }

  fn replace<'a>(&'a self, content: &'a [u8]) -> Cow<'a, [u8]> {
    self.regex.replace_all(content, &self.replace_with)
  }
}

#[derive(Parser)]
pub struct PatchIncludesOpts {
  /// Path to the input source file.
  input_path: String,

  /// Path to the output source file.
  output_path: String,

  /// The regular expression to find.
  find: String,

  /// The replacement string. Supports capture groups like $1, ${name}, etc.
  replace_with: String,

  #[arg(short = 'f', long, verbatim_doc_comment)]
  /**
   * Regex flags. May be combined (like `-f im`).
   *
   * c - case-sensitive (default).
   * i - case-insensitive.
   * m - multi-line mode (default).
   * e - disable multi-line matching.
   * s - `.` matches newline.
   * w - match whole words only.
   */
  flags: Option<String>,
}

pub fn run(opts: &PatchIncludesOpts) -> Result<()> {
  // Initialize the replacer
  let replacer = Replacer::new(
    opts.find.clone(),
    opts.replace_with.clone(),
    opts.flags.clone(),
  )?;

  // Set up tree-sitter parser for C++
  let mut parser = TsParser::new();
  let language = tree_sitter_cpp::LANGUAGE.into();
  parser
    .set_language(&language)
    .context("Failed to set tree-sitter C++ language")?;

  // Read and parse the source file
  let source_bytes = fs::read(&opts.input_path)
    .with_context(|| format!("Failed to read input file: {}", opts.input_path))?;
  let tree = parser
    .parse(&source_bytes, None)
    .context("Tree-sitter failed to parse the file")?;

  // Query for #include "..." paths
  let query_string = r#"(preproc_include path: (string_literal) @include_path)"#;
  let query = Query::new(&language, query_string)?;
  let mut query_cursor = QueryCursor::new();
  let mut captures = query_cursor.captures(&query, tree.root_node(), source_bytes.as_slice());

  // Collect all nodes to be processed
  let mut nodes: Vec<_> = Vec::new();
  while let Some(m) = captures.next() {
    nodes.push(m.0.captures.iter().map(|x| x.node).next().unwrap());
  }

  // Perform replacements in reverse to maintain valid byte offsets
  let mut source_list = source_bytes.to_vec();
  for node in nodes.iter().rev() {
    // The node is a string_literal, e.g., `"cplib.hpp"`.
    // We only want to replace the content *inside* the quotes.
    let start = node.start_byte();
    let end = node.end_byte();

    let path_inside_quotes = &source_list[(start + 1)..(end - 1)];
    let new_path_inside_quotes = replacer.replace(path_inside_quotes);

    // Only modify the source if a replacement actually happened
    if let Cow::Owned(new_path_bytes) = new_path_inside_quotes {
      let range_to_replace = (start + 1)..(end - 1);
      source_list.splice(range_to_replace, new_path_bytes.iter().cloned());
    }
  }

  // Write the modified content to the output file
  fs::write(&opts.output_path, source_list)
    .with_context(|| format!("Failed to write to output file: {}", opts.output_path))?;

  Ok(())
}
