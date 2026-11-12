//! A hand-written JSON parser and compact serializer.

use crate::error::{Error, Result};
use crate::object::Object;
use crate::value::Value;
use std::rc::Rc;

/// Maximum nesting depth accepted by the parser (guards the call stack).
const MAX_DEPTH: usize = 2000;

/// Parses a complete JSON document (exactly one value, surrounded by optional whitespace).
pub fn parse(text: &str) -> Result<Value> {
    let mut p = Parser { src: text, bytes: text.as_bytes(), pos: 0 };
    p.skip_ws();
    let v = p.value(0)?;
    p.skip_ws();
    if p.pos != p.bytes.len() {
        return Err(p.err("trailing characters after JSON value"));
    }
    Ok(v)
}

struct Parser<'a> {
    src: &'a str,
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn err(&self, msg: &str) -> Error {
        Error::json(format!("{} at byte {}", msg, self.pos))
    }

    fn skip_ws(&mut self) {
        while let Some(&b) = self.bytes.get(self.pos) {
            if matches!(b, b' ' | b'\t' | b'\n' | b'\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn value(&mut self, depth: usize) -> Result<Value> {
        if depth > MAX_DEPTH {
            return Err(self.err("nesting too deep"));
        }
        match self.bytes.get(self.pos) {
            None => Err(self.err("unexpected end of input")),
            Some(b'{') => self.object(depth),
            Some(b'[') => self.array(depth),
            Some(b'"') => Ok(Value::String(self.string()?.into())),
            Some(b't') => self.literal("true", Value::Bool(true)),
            Some(b'f') => self.literal("false", Value::Bool(false)),
            Some(b'n') => self.literal("null", Value::Null),
            Some(b'-') | Some(b'0'..=b'9') => self.number(),
            Some(_) => Err(self.err("unexpected character")),
        }
    }

    fn literal(&mut self, word: &str, v: Value) -> Result<Value> {
        if self.bytes[self.pos..].starts_with(word.as_bytes()) {
            self.pos += word.len();
            Ok(v)
        } else {
            Err(self.err("invalid literal"))
        }
    }

    fn number(&mut self) -> Result<Value> {
        let start = self.pos;
        let b = self.bytes;
        let mut i = self.pos;
        if b.get(i) == Some(&b'-') {
            i += 1;
        }
        match b.get(i) {
            Some(b'0') => i += 1,
            Some(b'1'..=b'9') => {
                while matches!(b.get(i), Some(b'0'..=b'9')) {
                    i += 1;
                }
            }
            _ => {
                self.pos = i;
                return Err(self.err("invalid number"));
            }
        }
        if b.get(i) == Some(&b'.') {
            i += 1;
            if !matches!(b.get(i), Some(b'0'..=b'9')) {
                self.pos = i;
                return Err(self.err("invalid number"));
            }
            while matches!(b.get(i), Some(b'0'..=b'9')) {
                i += 1;
            }
        }
        if matches!(b.get(i), Some(b'e') | Some(b'E')) {
            i += 1;
            if matches!(b.get(i), Some(b'+') | Some(b'-')) {
                i += 1;
            }
            if !matches!(b.get(i), Some(b'0'..=b'9')) {
                self.pos = i;
                return Err(self.err("invalid number"));
            }
            while matches!(b.get(i), Some(b'0'..=b'9')) {
                i += 1;
            }
        }
        self.pos = i;
        // `str::parse::<f64>` is correctly rounded (ties to even).
        match self.src[start..i].parse::<f64>() {
            Ok(n) => Ok(Value::Number(n)),
            Err(_) => Err(self.err("invalid number")),
        }
    }

    fn hex4(&mut self) -> Result<u32> {
        let mut n = 0u32;
        for _ in 0..4 {
            let d = match self.bytes.get(self.pos) {
                Some(c @ b'0'..=b'9') => c - b'0',
                Some(c @ b'a'..=b'f') => c - b'a' + 10,
                Some(c @ b'A'..=b'F') => c - b'A' + 10,
                _ => return Err(self.err("invalid \\u escape")),
            };
            n = n * 16 + d as u32;
            self.pos += 1;
        }
        Ok(n)
    }

    fn string(&mut self) -> Result<String> {
        self.pos += 1; // opening quote
        let start = self.pos;
        // Fast path: no escapes.
        while let Some(&c) = self.bytes.get(self.pos) {
            match c {
                b'"' => {
                    let s = self.src[start..self.pos].to_string();
                    self.pos += 1;
                    return Ok(s);
                }
                b'\\' => break,
                0..=0x1f => return Err(self.err("control character in string")),
                _ => self.pos += 1,
            }
        }
        let mut out = String::from(&self.src[start..self.pos]);
        loop {
            let seg = self.pos;
            while let Some(&c) = self.bytes.get(self.pos) {
                if c == b'"' || c == b'\\' || c < 0x20 {
                    break;
                }
                self.pos += 1;
            }
            out.push_str(&self.src[seg..self.pos]);
            match self.bytes.get(self.pos) {
                None => return Err(self.err("unterminated string")),
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.pos += 1;
                    let e = *self.bytes.get(self.pos).ok_or_else(|| self.err("unterminated string"))?;
                    self.pos += 1;
                    match e {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            let hi = self.hex4()?;
                            let cp = if (0xD800..0xDC00).contains(&hi) {
                                if self.bytes[self.pos..].starts_with(b"\\u") {
                                    self.pos += 2;
                                    let lo = self.hex4()?;
                                    if !(0xDC00..0xE000).contains(&lo) {
                                        return Err(self.err("invalid surrogate pair"));
                                    }
                                    0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                                } else {
                                    return Err(self.err("unpaired surrogate"));
                                }
                            } else {
                                hi
                            };
                            match char::from_u32(cp) {
                                Some(c) => out.push(c),
                                None => return Err(self.err("invalid code point")),
                            }
                        }
                        _ => return Err(self.err("invalid escape")),
                    }
                }
                Some(_) => return Err(self.err("control character in string")),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Result<Value> {
        self.pos += 1;
        let mut items = Vec::new();
        self.skip_ws();
        if self.bytes.get(self.pos) == Some(&b']') {
            self.pos += 1;
            return Ok(Value::array(items));
        }
        loop {
            self.skip_ws();
            items.push(self.value(depth + 1)?);
            self.skip_ws();
            match self.bytes.get(self.pos) {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Value::array(items));
                }
                _ => return Err(self.err("expected ',' or ']'")),
            }
        }
    }

    fn object(&mut self, depth: usize) -> Result<Value> {
        self.pos += 1;
        let mut obj = Object::new();
        self.skip_ws();
        if self.bytes.get(self.pos) == Some(&b'}') {
            self.pos += 1;
            return Ok(Value::object(obj));
        }
        loop {
            self.skip_ws();
            if self.bytes.get(self.pos) != Some(&b'"') {
                return Err(self.err("expected object key"));
            }
            let key: Rc<str> = self.string()?.into();
            self.skip_ws();
            if self.bytes.get(self.pos) != Some(&b':') {
                return Err(self.err("expected ':'"));
            }
            self.pos += 1;
            self.skip_ws();
            let v = self.value(depth + 1)?;
            obj.insert(key, v);
            self.skip_ws();
            match self.bytes.get(self.pos) {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Value::object(obj));
                }
                _ => return Err(self.err("expected ',' or '}'")),
            }
        }
    }
}

/// Checks that `s` is exactly one JSON number and returns its value.
pub(crate) fn parse_number(s: &str) -> Option<f64> {
    match parse(s) {
        Ok(Value::Number(n)) if !s.starts_with([' ', '\t', '\n', '\r']) && !s.ends_with([' ', '\t', '\n', '\r']) => {
            Some(n)
        }
        _ => None,
    }
}

/// Serializes a value as compact JSON.
pub fn to_string(v: &Value) -> String {
    let mut s = String::new();
    write_value(v, &mut s);
    s
}

/// Appends the compact JSON form of `v` to `out`.
pub fn write_value(v: &Value, out: &mut String) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Number(n) => write_number(*n, out),
        Value::String(s) => write_string(s, out),
        Value::Array(a) => {
            out.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_value(x, out);
            }
            out.push(']');
        }
        Value::Object(o) => {
            out.push('{');
            for (i, (k, x)) in o.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_string(k, out);
                out.push(':');
                write_value(x, out);
            }
            out.push('}');
        }
    }
}

/// Appends a number: integers without a decimal point, other values in their
/// shortest round-trip decimal form.
pub fn write_number(n: f64, out: &mut String) {
    use std::fmt::Write;
    if n.is_nan() {
        out.push_str("null");
    } else if n.is_infinite() {
        out.push_str(if n > 0.0 { "1.7976931348623157e+308" } else { "-1.7976931348623157e+308" });
    } else if n == 0.0 {
        out.push_str(if n.is_sign_negative() { "-0" } else { "0" });
    } else if n.fract() == 0.0 && n.abs() < 1e17 {
        let _ = write!(out, "{}", n as i64);
    } else {
        let _ = write!(out, "{}", n);
    }
}

/// Appends a JSON string literal with the escaping rules of the specification.
pub fn write_string(s: &str, out: &mut String) {
    out.push('"');
    let mut run = 0; // start of the pending unescaped run
    for (i, c) in s.char_indices() {
        let esc: Option<&str> = match c {
            '"' => Some("\\\""),
            '\\' => Some("\\\\"),
            '\u{8}' => Some("\\b"),
            '\u{c}' => Some("\\f"),
            '\n' => Some("\\n"),
            '\r' => Some("\\r"),
            '\t' => Some("\\t"),
            _ => None,
        };
        if esc.is_some() || (c as u32) < 0x20 || c == '\u{7f}' {
            out.push_str(&s[run..i]);
            run = i + c.len_utf8();
            match esc {
                Some(e) => out.push_str(e),
                None => {
                    use std::fmt::Write;
                    let _ = write!(out, "\\u{:04x}", c as u32);
                }
            }
        }
    }
    out.push_str(&s[run..]);
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_scalars_and_containers() {
        assert_eq!(to_string(&parse(" [1, 2.5, \"a\", null, true, {\"k\": []}] ").unwrap()), r#"[1,2.5,"a",null,true,{"k":[]}]"#);
    }

    #[test]
    fn surrogate_pairs_and_escapes() {
        let v = parse(r#""\ud83d\ude00 \u00e9 \/ \b""#).unwrap();
        assert_eq!(to_string(&v), "\"😀 é / \\b\"");
    }

    #[test]
    fn rejects_malformed_input() {
        for bad in ["", "[1,]", "{\"a\"}", "01", "1.", "\"\\ud800\"", "[1] x", "\"a\nb\"", "tru"] {
            assert!(parse(bad).is_err(), "{bad:?} should be rejected");
        }
    }

    #[test]
    fn number_formatting() {
        let f = |n: f64| {
            let mut s = String::new();
            write_number(n, &mut s);
            s
        };
        assert_eq!(f(3.0), "3");
        assert_eq!(f(-12.0), "-12");
        assert_eq!(f(0.125), "0.125");
        assert_eq!(f(1e12), "1000000000000");
        assert_eq!(f(0.1 + 0.2), "0.30000000000000004");
    }

    #[test]
    fn numbers_round_correctly() {
        assert_eq!(parse("0.1").unwrap(), Value::Number(0.1));
        assert_eq!(parse("1e2").unwrap(), Value::Number(100.0));
    }

    #[test]
    fn object_order_is_document_order() {
        assert_eq!(to_string(&parse(r#"{"b":1,"a":2,"c":3}"#).unwrap()), r#"{"b":1,"a":2,"c":3}"#);
    }
}
