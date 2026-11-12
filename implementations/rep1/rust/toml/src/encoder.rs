//! The canonical TOML serializer.

use crate::error::TaggedError;
use crate::value::{Table, Value};

/// Renders a tree as canonical TOML.
///
/// The root must be a table. Within each table all plain values are written
/// first (keys in code-point order), then sub-tables and arrays of tables,
/// each under its own header. The output always ends with a single newline.
/// For any tree produced by the decoder, parsing the output yields the same
/// tree again.
pub fn to_toml(root: &Value) -> Result<String, TaggedError> {
    match root {
        Value::Table(t) => {
            let mut out = String::new();
            let mut path = Vec::new();
            write_table(t, &mut path, &mut out);
            if out.is_empty() {
                out.push('\n');
            }
            Ok(out)
        }
        _ => Err(TaggedError::new("the root of a document must be a table")),
    }
}

/// An "array of tables": non-empty and made only of tables.
fn is_array_of_tables(items: &[Value]) -> bool {
    !items.is_empty() && items.iter().all(|v| matches!(v, Value::Table(_)))
}

fn write_table(table: &Table, path: &mut Vec<String>, out: &mut String) {
    for (key, value) in table {
        let is_block = match value {
            Value::Table(_) => true,
            Value::Array(items) => is_array_of_tables(items),
            Value::Scalar(_) => false,
        };
        if !is_block {
            out.push_str(&render_key(key));
            out.push_str(" = ");
            write_inline(value, out);
            out.push('\n');
        }
    }
    for (key, value) in table {
        path.push(render_key(key));
        match value {
            Value::Table(sub) => {
                write_header(path, false, out);
                write_table(sub, path, out);
            }
            Value::Array(items) if is_array_of_tables(items) => {
                for item in items {
                    if let Value::Table(sub) = item {
                        write_header(path, true, out);
                        write_table(sub, path, out);
                    }
                }
            }
            _ => {}
        }
        path.pop();
    }
}

fn write_header(path: &[String], array: bool, out: &mut String) {
    if !out.is_empty() {
        out.push('\n');
    }
    out.push_str(if array { "[[" } else { "[" });
    out.push_str(&path.join("."));
    out.push_str(if array { "]]" } else { "]" });
    out.push('\n');
}

fn write_inline(value: &Value, out: &mut String) {
    match value {
        Value::Scalar(s) => match s.kind {
            crate::value::ScalarKind::String => write_basic_string(&s.text, out),
            _ => out.push_str(&s.text),
        },
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push_str(", ");
                }
                write_inline(item, out);
            }
            out.push(']');
        }
        Value::Table(t) => {
            out.push('{');
            for (i, (k, v)) in t.iter().enumerate() {
                if i > 0 {
                    out.push_str(", ");
                }
                out.push_str(&render_key(k));
                out.push_str(" = ");
                write_inline(v, out);
            }
            out.push('}');
        }
    }
}

fn render_key(key: &str) -> String {
    if !key.is_empty()
        && key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        key.to_string()
    } else {
        let mut s = String::new();
        write_basic_string(key, &mut s);
        s
    }
}

fn write_basic_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\u{c}' => out.push_str("\\f"),
            '\r' => out.push_str("\\r"),
            c if (c as u32) < 0x20 || c == '\u{7f}' => {
                out.push_str(&format!("\\u{:04x}", c as u32))
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tagged_json;

    fn enc(json: &str) -> String {
        to_toml(&tagged_json::from_str(json).unwrap()).unwrap()
    }

    #[test]
    fn empty_root() {
        assert_eq!(enc("{}"), "\n");
    }

    #[test]
    fn nested_headers_and_blank_lines() {
        let out = enc(r#"{"a":{"b":{"c":{"type":"integer","value":"1"}}}}"#);
        assert_eq!(out, "[a]\n\n[a.b]\nc = 1\n");
    }

    #[test]
    fn quoting_and_inline() {
        let out = enc(r#"{"a b":[{"x":{"type":"bool","value":"true"}},{"type":"integer","value":"2"}],"e":[],"\u0001":{"type":"string","value":"\u007f"}}"#);
        assert_eq!(out, "\"\\u0001\" = \"\\u007f\"\n\"a b\" = [{x = true}, 2]\ne = []\n");
    }

    #[test]
    fn arrays_of_tables() {
        let out = enc(r#"{"f":[{"n":{"type":"integer","value":"1"}},{}]}"#);
        assert_eq!(out, "[[f]]\nn = 1\n\n[[f]]\n");
    }
}
