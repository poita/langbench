//! Reading and writing the *tagged JSON* interchange format.
//!
//! A table is a JSON object, an array is a JSON array, and a scalar is an
//! object `{"type": …, "value": …}` with two string members. The writer emits
//! compact JSON with object members sorted by key.

use std::collections::BTreeMap;

use crate::error::TaggedError;
use crate::value::{Scalar, ScalarKind, Table, Value};

const MAX_DEPTH: usize = 2_000;

// ---- writer --------------------------------------------------------------

/// Serialises a tree as compact, key-sorted tagged JSON (no trailing newline).
pub fn to_string(value: &Value) -> String {
    let mut out = String::new();
    write_value(value, &mut out);
    out
}

fn write_value(value: &Value, out: &mut String) {
    match value {
        Value::Scalar(s) => {
            out.push_str("{\"type\":");
            write_json_string(s.kind.tag(), out);
            out.push_str(",\"value\":");
            write_json_string(&s.text, out);
            out.push('}');
        }
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_value(item, out);
            }
            out.push(']');
        }
        Value::Table(table) => {
            out.push('{');
            for (i, (key, item)) in table.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_json_string(key, out);
                out.push(':');
                write_value(item, out);
            }
            out.push('}');
        }
    }
}

fn write_json_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

// ---- generic JSON reader ---------------------------------------------------

#[derive(Debug)]
enum Json {
    /// `true`, `false` or `null`: valid JSON, never valid tagged JSON.
    Literal,
    Number,
    String(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

struct JsonReader<'a> {
    src: &'a [u8],
    pos: usize,
}

type Res<T> = Result<T, TaggedError>;

impl<'a> JsonReader<'a> {
    fn err<T>(&self, msg: &str) -> Res<T> {
        Err(TaggedError::new(format!("invalid JSON at byte {}: {msg}", self.pos)))
    }

    fn ws(&mut self) {
        while matches!(self.src.get(self.pos), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.pos += 1;
        }
    }

    fn eat(&mut self, b: u8) -> bool {
        if self.src.get(self.pos) == Some(&b) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn literal(&mut self, word: &str) -> Res<Json> {
        if self.src[self.pos..].starts_with(word.as_bytes()) {
            self.pos += word.len();
            Ok(Json::Literal)
        } else {
            self.err("bad literal")
        }
    }

    fn value(&mut self, depth: usize) -> Res<Json> {
        if depth > MAX_DEPTH {
            return self.err("nesting too deep");
        }
        self.ws();
        match self.src.get(self.pos) {
            None => self.err("unexpected end of input"),
            Some(b'{') => {
                self.pos += 1;
                let mut members = Vec::new();
                self.ws();
                if self.eat(b'}') {
                    return Ok(Json::Object(members));
                }
                loop {
                    self.ws();
                    if self.src.get(self.pos) != Some(&b'"') {
                        return self.err("expected object key");
                    }
                    let key = self.string()?;
                    self.ws();
                    if !self.eat(b':') {
                        return self.err("expected ':'");
                    }
                    members.push((key, self.value(depth + 1)?));
                    self.ws();
                    if self.eat(b',') {
                        continue;
                    }
                    if self.eat(b'}') {
                        return Ok(Json::Object(members));
                    }
                    return self.err("expected ',' or '}'");
                }
            }
            Some(b'[') => {
                self.pos += 1;
                let mut items = Vec::new();
                self.ws();
                if self.eat(b']') {
                    return Ok(Json::Array(items));
                }
                loop {
                    items.push(self.value(depth + 1)?);
                    self.ws();
                    if self.eat(b',') {
                        continue;
                    }
                    if self.eat(b']') {
                        return Ok(Json::Array(items));
                    }
                    return self.err("expected ',' or ']'");
                }
            }
            Some(b'"') => Ok(Json::String(self.string()?)),
            Some(b't') => self.literal("true"),
            Some(b'f') => self.literal("false"),
            Some(b'n') => self.literal("null"),
            Some(b'-' | b'0'..=b'9') => {
                while matches!(
                    self.src.get(self.pos),
                    Some(b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9')
                ) {
                    self.pos += 1;
                }
                Ok(Json::Number)
            }
            Some(_) => self.err("unexpected character"),
        }
    }

    fn hex4(&mut self) -> Res<u32> {
        let mut v = 0;
        for _ in 0..4 {
            match self.src.get(self.pos).and_then(|&b| (b as char).to_digit(16)) {
                Some(d) => v = v * 16 + d,
                None => return self.err("bad \\u escape"),
            }
            self.pos += 1;
        }
        Ok(v)
    }

    fn string(&mut self) -> Res<String> {
        self.pos += 1; // opening quote
        let mut buf = Vec::new();
        loop {
            let b = match self.src.get(self.pos) {
                Some(&b) => b,
                None => return self.err("unterminated string"),
            };
            self.pos += 1;
            match b {
                b'"' => break,
                b'\\' => {
                    let e = match self.src.get(self.pos) {
                        Some(&e) => e,
                        None => return self.err("unterminated escape"),
                    };
                    self.pos += 1;
                    let ch = match e {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => {
                            let hi = self.hex4()?;
                            let cp = if (0xD800..0xDC00).contains(&hi) {
                                if !self.src[self.pos..].starts_with(b"\\u") {
                                    return self.err("lone surrogate");
                                }
                                self.pos += 2;
                                let lo = self.hex4()?;
                                if !(0xDC00..0xE000).contains(&lo) {
                                    return self.err("lone surrogate");
                                }
                                0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                            } else {
                                hi
                            };
                            match char::from_u32(cp) {
                                Some(c) => c,
                                None => return self.err("lone surrogate"),
                            }
                        }
                        _ => return self.err("bad escape"),
                    };
                    let mut tmp = [0u8; 4];
                    buf.extend_from_slice(ch.encode_utf8(&mut tmp).as_bytes());
                }
                _ => buf.push(b),
            }
        }
        String::from_utf8(buf).or_else(|_| self.err("invalid UTF-8"))
    }
}

// ---- conversion to Value -----------------------------------------------------

fn to_value(json: Json) -> Res<Value> {
    match json {
        Json::Array(items) => items
            .into_iter()
            .map(to_value)
            .collect::<Res<Vec<_>>>()
            .map(Value::Array),
        Json::Object(members) => object_to_value(members),
        Json::String(_) | Json::Number | Json::Literal => {
            Err(TaggedError::new("bare JSON scalar where a table, array or value node is expected"))
        }
    }
}

fn object_to_value(members: Vec<(String, Json)>) -> Res<Value> {
    if let [(k1, v1), (k2, v2)] = members.as_slice() {
        let (ty, val) = match (k1.as_str(), k2.as_str()) {
            ("type", "value") => (v1, v2),
            ("value", "type") => (v2, v1),
            _ => (&Json::Literal, &Json::Literal),
        };
        if let (Json::String(ty), Json::String(val)) = (ty, val) {
            if let Some(kind) = ScalarKind::from_tag(ty) {
                return Ok(Value::Scalar(Scalar::new(kind, val.clone())));
            }
        }
    }
    let mut table: Table = BTreeMap::new();
    for (k, v) in members {
        if table.insert(k, to_value(v)?).is_some() {
            return Err(TaggedError::new("duplicate key in JSON object"));
        }
    }
    Ok(Value::Table(table))
}

/// Parses tagged JSON into a [`Value`] tree.
///
/// An object is a scalar node exactly when it has the two string members
/// `type` and `value` and `type` names one of the eight scalar types;
/// otherwise it is a table.
pub fn from_str(input: &str) -> Result<Value, TaggedError> {
    let mut reader = JsonReader {
        src: input.as_bytes(),
        pos: 0,
    };
    let json = reader.value(0)?;
    reader.ws();
    if reader.pos != reader.src.len() {
        return reader.err("trailing characters");
    }
    to_value(json)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_sorted_compact_json() {
        let mut t = Table::new();
        t.insert("b".into(), Value::integer(1));
        t.insert("a".into(), Value::string("x\"\u{1}\u{7f}é"));
        assert_eq!(
            to_string(&Value::Table(t)),
            "{\"a\":{\"type\":\"string\",\"value\":\"x\\\"\\u0001\u{7f}é\"},\"b\":{\"type\":\"integer\",\"value\":\"1\"}}"
        );
    }

    #[test]
    fn reads_whitespace_and_order() {
        let v = from_str(" { \"a\" : { \"value\" : \"1\", \"type\":\"integer\" } , \"b\":[ ] } ").unwrap();
        assert_eq!(v.get("a"), Some(&Value::integer(1)));
        assert_eq!(v.get("b"), Some(&Value::Array(vec![])));
    }

    #[test]
    fn table_with_type_and_value_keys() {
        let v = from_str(r#"{"type":{"type":"string","value":"a"},"value":{"type":"string","value":"b"}}"#).unwrap();
        assert!(v.as_table().is_some());
        assert_eq!(v.get("type"), Some(&Value::string("a")));
    }

    #[test]
    fn string_escapes() {
        let v = from_str(r#"{"k":{"type":"string","value":"\ud83d\ude00\u0000\/"}}"#).unwrap();
        assert_eq!(v.get("k").and_then(Value::as_str), Some("😀\0/"));
    }

    #[test]
    fn rejects_garbage() {
        assert!(from_str("{").is_err());
        assert!(from_str("{} x").is_err());
        assert!(from_str(r#"{"a":"s"}"#).is_err());
    }
}
