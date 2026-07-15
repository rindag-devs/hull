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

use std::{collections::BTreeMap, fmt, io::Read};

use anyhow::{Context, Result, anyhow, bail};
use clap::{Parser, ValueEnum};
use serde::{Deserialize, Deserializer, de};
use tree_sitter::{Language, Node, Parser as TsParser};

const MARKER: &str = "hull_source_config";

/// Source language used to parse configuration comments.
#[derive(Clone, Copy, Debug, Eq, PartialEq, ValueEnum)]
pub enum SourceLanguage {
  /// C source code.
  C,
  /// C++ source code.
  Cpp,
}

/// Options for extracting configuration from source code.
#[derive(Parser)]
pub struct SourceConfigOpts {
  /// Language of the source code read from standard input.
  #[arg(value_enum)]
  pub language: SourceLanguage,
}

#[derive(Debug)]
enum ConfigValue {
  String(String),
  Bool(bool),
  Integer(i64),
}

impl<'de> Deserialize<'de> for ConfigValue {
  fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
  where
    D: Deserializer<'de>,
  {
    struct ValueVisitor;

    impl<'de> de::Visitor<'de> for ValueVisitor {
      type Value = ConfigValue;

      fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a string, boolean, or signed integer")
      }

      fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
      where
        E: de::Error,
      {
        Ok(ConfigValue::String(value.to_owned()))
      }

      fn visit_bool<E>(self, value: bool) -> Result<Self::Value, E> {
        Ok(ConfigValue::Bool(value))
      }

      fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E> {
        Ok(ConfigValue::Integer(value))
      }

      fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E>
      where
        E: de::Error,
      {
        i64::try_from(value)
          .map(ConfigValue::Integer)
          .map_err(|_| de::Error::custom("integer is outside the signed 64-bit range"))
      }
    }

    deserializer.deserialize_any(ValueVisitor)
  }
}

struct SourceConfig(BTreeMap<String, ConfigValue>);

impl<'de> Deserialize<'de> for SourceConfig {
  fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
  where
    D: Deserializer<'de>,
  {
    struct ConfigVisitor;

    impl<'de> de::Visitor<'de> for ConfigVisitor {
      type Value = SourceConfig;

      fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a JSON object")
      }

      fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
      where
        A: de::MapAccess<'de>,
      {
        let mut values = BTreeMap::new();
        while let Some((key, value)) = map.next_entry::<String, ConfigValue>()? {
          if values.insert(key.clone(), value).is_some() {
            return Err(de::Error::custom(format!("duplicate key `{key}`")));
          }
        }
        Ok(SourceConfig(values))
      }
    }

    deserializer.deserialize_map(ConfigVisitor)
  }
}

/// Reads source code from standard input and prints its Hull configuration as TSV.
pub fn run(opts: &SourceConfigOpts) -> Result<()> {
  let mut source = Vec::new();
  std::io::stdin()
    .read_to_end(&mut source)
    .context("Failed to read source code from stdin")?;

  if let Some(output) = extract_source_config(&source, opts.language)? {
    print!("{output}");
  }
  Ok(())
}

fn extract_source_config(source: &[u8], source_language: SourceLanguage) -> Result<Option<String>> {
  let language: Language = match source_language {
    SourceLanguage::C => tree_sitter_c::LANGUAGE.into(),
    SourceLanguage::Cpp => tree_sitter_cpp::LANGUAGE.into(),
  };
  let mut parser = TsParser::new();
  parser
    .set_language(&language)
    .context("Failed to set up tree-sitter source language")?;
  let tree = parser
    .parse(source, None)
    .context("Tree-sitter failed to parse source code")?;

  let mut cursor = tree.walk();
  loop {
    let node = cursor.node();
    if node.kind() == "comment"
      && let Some(json) = config_json(node, source)?
    {
      return parse_config(&json).map(Some);
    }

    if cursor.goto_first_child() {
      continue;
    }
    while !cursor.goto_next_sibling() {
      if !cursor.goto_parent() {
        return Ok(None);
      }
    }
  }
}

fn config_json(node: Node<'_>, source: &[u8]) -> Result<Option<String>> {
  let comment = &source[node.byte_range()];
  let json = if let Some(body) = comment.strip_prefix(b"//") {
    strip_marker(body.trim_ascii_start()).map(ToOwned::to_owned)
  } else if let Some(body) = comment
    .strip_prefix(b"/*")
    .and_then(|body| body.strip_suffix(b"*/"))
  {
    let mut normalized = Vec::with_capacity(body.len());
    for line in body.split(|byte| *byte == b'\n') {
      if !normalized.is_empty() {
        normalized.push(b'\n');
      }
      let line = line.trim_ascii_start();
      normalized.extend_from_slice(line.strip_prefix(b"*").unwrap_or(line).trim_ascii_start());
    }
    strip_marker(normalized.trim_ascii_start()).map(ToOwned::to_owned)
  } else {
    None
  };
  json
    .map(|json| {
      std::str::from_utf8(&json)
        .context("Failed to extract UTF-8 source configuration")
        .map(str::to_owned)
    })
    .transpose()
}

fn strip_marker(body: &[u8]) -> Option<&[u8]> {
  let rest = body.strip_prefix(MARKER.as_bytes())?;
  if rest.is_empty() || rest[0].is_ascii_whitespace() || rest[0] == b'{' {
    Some(rest.trim_ascii_start())
  } else {
    None
  }
}

fn parse_config(json: &str) -> Result<String> {
  let config: SourceConfig = serde_json::from_str(json)
    .map_err(|error| anyhow!("Malformed source configuration JSON: {error}"))?;
  let mut output = String::new();
  for (key, value) in config.0 {
    validate_text(&key)?;
    match value {
      ConfigValue::String(value) => {
        validate_text(&value)?;
        output.push_str(&format!("{key}\tstring\t{value}\n"));
      }
      ConfigValue::Bool(value) => output.push_str(&format!("{key}\tbool\t{value}\n")),
      ConfigValue::Integer(value) => output.push_str(&format!("{key}\tinteger\t{value}\n")),
    }
  }
  Ok(output)
}

fn validate_text(value: &str) -> Result<()> {
  if !value.bytes().all(|byte| (b' '..=b'~').contains(&byte)) {
    bail!("Configuration keys and strings must be safe single-line ASCII");
  }
  Ok(())
}

#[cfg(test)]
mod tests {
  use super::*;

  fn extract(source: &str, language: SourceLanguage) -> anyhow::Result<Option<String>> {
    extract_source_config(source.as_bytes(), language)
  }

  #[test]
  fn extracts_c_block() -> anyhow::Result<()> {
    let output = extract(
      "/* hull_source_config {\"std\":\"c17\",\"optimize\":true,\"limit\":42} */\nint main(void) {}",
      SourceLanguage::C,
    )?;

    assert_eq!(
      output.as_deref(),
      Some("limit\tinteger\t42\noptimize\tbool\ttrue\nstd\tstring\tc17\n")
    );
    Ok(())
  }

  #[test]
  fn extracts_cpp_line() -> anyhow::Result<()> {
    let output = extract(
      "// hull_source_config {\"std\":\"c++23\"}\nint main() {}",
      SourceLanguage::Cpp,
    )?;

    assert_eq!(output.as_deref(), Some("std\tstring\tc++23\n"));
    Ok(())
  }

  #[test]
  fn normalizes_leading_stars() -> anyhow::Result<()> {
    let output = extract(
      "/**\n * hull_source_config {\n *   \"std\": \"c++20\",\n *   \"sanitize\": false\n * }\n */",
      SourceLanguage::Cpp,
    )?;

    assert_eq!(
      output.as_deref(),
      Some("sanitize\tbool\tfalse\nstd\tstring\tc++20\n")
    );
    Ok(())
  }

  #[test]
  fn skips_unrelated_and_string_comments() -> anyhow::Result<()> {
    let output = extract(
      "const char *fake = \"// hull_source_config {\\\"wrong\\\":true}\";\n/* unrelated */\n/* hull_source_config {\"right\":true} */",
      SourceLanguage::C,
    )?;

    assert_eq!(output.as_deref(), Some("right\tbool\ttrue\n"));
    Ok(())
  }

  #[test]
  fn uses_first_matching_comment() -> anyhow::Result<()> {
    let output = extract(
      "// hull_source_config_aaaaa {\"wrong\":true}\n// hull_source_config {\"first\":1}\n// hull_source_config {\"second\":2}",
      SourceLanguage::Cpp,
    )?;

    assert_eq!(output.as_deref(), Some("first\tinteger\t1\n"));
    Ok(())
  }

  #[test]
  fn no_marker_is_empty() -> anyhow::Result<()> {
    assert_eq!(extract("// ordinary comment", SourceLanguage::C)?, None);
    Ok(())
  }

  #[test]
  fn parser_recovery() -> anyhow::Result<()> {
    assert_eq!(
      extract(
        "using cplib::var::Reader, cplib::var::i32;",
        SourceLanguage::Cpp
      )?,
      None
    );
    Ok(())
  }

  #[test]
  fn rejects_duplicate_keys() {
    let error = extract(
      "// hull_source_config {\"std\":\"c17\",\"std\":\"c23\"}",
      SourceLanguage::C,
    )
    .expect_err("duplicate keys must fail");

    assert!(error.to_string().contains("duplicate key"));
  }

  #[test]
  fn rejects_invalid_shapes() {
    for json in [
      "null",
      "[]",
      "\"text\"",
      "{\"value\":null}",
      "{\"value\":[]}",
      "{\"value\":{}}",
      "{\"value\":1.5}",
    ] {
      let source = format!("// hull_source_config {json}");
      assert!(
        extract(&source, SourceLanguage::Cpp).is_err(),
        "accepted {json}"
      );
    }
  }

  #[test]
  fn signed_integers() -> anyhow::Result<()> {
    let output = extract(
      "// hull_source_config {\"min\":-9223372036854775808,\"max\":9223372036854775807}",
      SourceLanguage::C,
    )?;

    assert_eq!(
      output.as_deref(),
      Some("max\tinteger\t9223372036854775807\nmin\tinteger\t-9223372036854775808\n")
    );
    assert!(
      extract(
        "// hull_source_config {\"value\":9223372036854775808}",
        SourceLanguage::C
      )
      .is_err()
    );
    Ok(())
  }

  #[test]
  fn skips_non_utf8_comment() -> anyhow::Result<()> {
    let source = b"/* unrelated: \xff */\n/* hull_source_config {\"optimize\":\"2\"} */";
    let output = extract_source_config(source, SourceLanguage::Cpp)?;

    assert_eq!(output.as_deref(), Some("optimize\tstring\t2\n"));
    Ok(())
  }

  #[test]
  fn rejects_unsafe_tsv_text() {
    for json in [
      "{\"bad\\tkey\":true}",
      "{\"value\":\"bad\\ttext\"}",
      "{\"value\":\"bad\\ntext\"}",
      "{\"value\":\"bad\\u0000text\"}",
      "{\"value\":\"non-ASCII: \\u00e9\"}",
    ] {
      let source = format!("// hull_source_config {json}");
      let error = extract(&source, SourceLanguage::C).expect_err("unsafe text must fail");
      assert!(error.to_string().contains("safe single-line ASCII"));
    }
  }
}
