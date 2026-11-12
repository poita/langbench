//! JSON parsing and serialization (hand-written, no external crates).

use std::fmt::Write;
use std::rc::Rc;

use crate::error::JsonError;
use crate::object::Object;
use crate::value::Value;

/// Maximum nesting depth accepted by the parser.
pub const MAX_DEPTH: usize = 1000;

// ---------------------------------------------------------------- parsing

impl Value {
    /// Parses a complete JSON document (one value surrounded by optional
    /// whitespace).
    ///
    /// ```
    /// use jq_subset::Value;
    /// let v = Value::parse_json(r#"{"a":[1,2.5,"x"]}"#).unwrap();
    /// assert_eq!(v.to_json(), r#"{"a":[1,2.5,"x"]}"#);
    /// ```
    pub fn parse_json(text: &str) -> Result<Value, JsonError> {
        let mut p = Parser { src: text, bytes: text.as_bytes(), pos: 0 };
        p.skip_ws();
        let v = p.value(0)?;
        p.skip_ws();
        if p.pos != p.bytes.len() {
            return Err(p.err("trailing characters after JSON value"));
        }
        Ok(v)
    }
}

struct Parser<'a> {
    src: &'a str,
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn err(&self, message: &str) -> JsonError {
        JsonError { message: message.to_string(), offset: self.pos }
    }

    fn skip_ws(&mut self) {
        while let Some(b' ' | b'\t' | b'\n' | b'\r') = self.bytes.get(self.pos) {
            self.pos += 1;
        }
    }

    fn value(&mut self, depth: usize) -> Result<Value, JsonError> {
        if depth > MAX_DEPTH {
            return Err(self.err("nesting too deep"));
        }
        match self.bytes.get(self.pos) {
            None => Err(self.err("unexpected end of input")),
            Some(b'n') => self.literal("null", Value::Null),
            Some(b't') => self.literal("true", Value::Bool(true)),
            Some(b'f') => self.literal("false", Value::Bool(false)),
            Some(b'"') => {
                let (s, end) = parse_string(self.src, self.pos)?;
                self.pos = end;
                Ok(Value::String(s))
            }
            Some(b'[') => self.array(depth),
            Some(b'{') => self.object(depth),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(_) => Err(self.err("unexpected character")),
        }
    }

    fn literal(&mut self, word: &str, v: Value) -> Result<Value, JsonError> {
        if self.bytes[self.pos..].starts_with(word.as_bytes()) {
            self.pos += word.len();
            Ok(v)
        } else {
            Err(self.err("invalid literal"))
        }
    }

    fn number(&mut self) -> Result<Value, JsonError> {
        let start = self.pos;
        let b = self.bytes;
        let mut i = start;
        if b.get(i) == Some(&b'-') {
            i += 1;
        }
        match b.get(i) {
            Some(b'0') => i += 1,
            Some(b'1'..=b'9') => {
                while let Some(b'0'..=b'9') = b.get(i) {
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
            let ds = i;
            while let Some(b'0'..=b'9') = b.get(i) {
                i += 1;
            }
            if i == ds {
                self.pos = i;
                return Err(self.err("digit expected after decimal point"));
            }
        }
        if let Some(b'e' | b'E') = b.get(i) {
            i += 1;
            if let Some(b'+' | b'-') = b.get(i) {
                i += 1;
            }
            let ds = i;
            while let Some(b'0'..=b'9') = b.get(i) {
                i += 1;
            }
            if i == ds {
                self.pos = i;
                return Err(self.err("digit expected in exponent"));
            }
        }
        self.pos = i;
        match self.src[start..i].parse::<f64>() {
            Ok(n) => Ok(Value::Number(n)),
            Err(_) => Err(self.err("invalid number")),
        }
    }

    fn array(&mut self, depth: usize) -> Result<Value, JsonError> {
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

    fn object(&mut self, depth: usize) -> Result<Value, JsonError> {
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
            let (key, end) = parse_string(self.src, self.pos)?;
            self.pos = end;
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

fn hex4(bytes: &[u8], at: usize) -> Option<u32> {
    let chunk = bytes.get(at..at + 4)?;
    let mut n = 0u32;
    for &c in chunk {
        n = n * 16 + (c as char).to_digit(16)?;
    }
    Some(n)
}

/// Parses a JSON string literal whose opening quote is at byte `start` of
/// `src`. Returns the decoded string and the offset just past the closing
/// quote. Shared with the filter lexer, whose string literals use JSON syntax.
pub(crate) fn parse_string(src: &str, start: usize) -> Result<(Rc<str>, usize), JsonError> {
    let bytes = src.as_bytes();
    let err = |offset: usize, m: &str| JsonError { message: m.to_string(), offset };
    let mut i = start + 1;
    // Fast path: no escapes.
    let run = i;
    while let Some(&c) = bytes.get(i) {
        match c {
            b'"' => return Ok((Rc::from(&src[run..i]), i + 1)),
            b'\\' => break,
            0..=0x1f => return Err(err(i, "control character in string")),
            _ => i += 1,
        }
    }
    let mut out = String::with_capacity(i - run + 16);
    out.push_str(&src[run..i]);
    loop {
        let run = i;
        while let Some(&c) = bytes.get(i) {
            if c == b'"' || c == b'\\' || c < 0x20 {
                break;
            }
            i += 1;
        }
        out.push_str(&src[run..i]);
        match bytes.get(i) {
            None => return Err(err(i, "unterminated string")),
            Some(b'"') => return Ok((Rc::from(out), i + 1)),
            Some(b'\\') => {
                let esc = bytes.get(i + 1).copied();
                i += 2;
                match esc {
                    Some(b'"') => out.push('"'),
                    Some(b'\\') => out.push('\\'),
                    Some(b'/') => out.push('/'),
                    Some(b'b') => out.push('\u{8}'),
                    Some(b'f') => out.push('\u{c}'),
                    Some(b'n') => out.push('\n'),
                    Some(b'r') => out.push('\r'),
                    Some(b't') => out.push('\t'),
                    Some(b'u') => {
                        let hi = hex4(bytes, i).ok_or_else(|| err(i, "invalid \\u escape"))?;
                        i += 4;
                        let cp = if (0xD800..0xDC00).contains(&hi) {
                            if bytes.get(i) == Some(&b'\\') && bytes.get(i + 1) == Some(&b'u') {
                                match hex4(bytes, i + 2) {
                                    Some(lo) if (0xDC00..0xE000).contains(&lo) => {
                                        i += 6;
                                        0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                                    }
                                    _ => 0xFFFD,
                                }
                            } else {
                                0xFFFD
                            }
                        } else {
                            hi
                        };
                        out.push(char::from_u32(cp).unwrap_or('\u{FFFD}'));
                    }
                    _ => return Err(err(i - 1, "invalid escape")),
                }
            }
            Some(_) => return Err(err(i, "control character in string")),
        }
    }
}

// ---------------------------------------------------------- serialization

/// Appends `s` to `out` as a JSON string literal.
pub fn write_json_string(s: &str, out: &mut String) {
    out.push('"');
    let bytes = s.as_bytes();
    let mut run = 0;
    for (i, &c) in bytes.iter().enumerate() {
        let esc: &str = match c {
            b'"' => "\\\"",
            b'\\' => "\\\\",
            0x08 => "\\b",
            0x0c => "\\f",
            b'\n' => "\\n",
            b'\r' => "\\r",
            b'\t' => "\\t",
            0..=0x1f | 0x7f => "",
            _ => continue,
        };
        out.push_str(&s[run..i]);
        if esc.is_empty() {
            let _ = write!(out, "\\u{:04x}", c);
        } else {
            out.push_str(esc);
        }
        run = i + 1;
    }
    out.push_str(&s[run..]);
    out.push('"');
}

/// Appends the canonical text of a number to `out`.
///
/// Integral values print without a decimal point; other values print in the
/// shortest decimal form that round-trips.
pub fn write_json_number(n: f64, out: &mut String) {
    if n.is_nan() {
        out.push_str("null");
    } else if n.is_infinite() {
        out.push_str(if n > 0.0 { "1.7976931348623157e+308" } else { "-1.7976931348623157e+308" });
    } else if n == 0.0 {
        out.push_str(if n.is_sign_negative() { "-0" } else { "0" });
    } else if n.fract() == 0.0 && n.abs() < 1e17 {
        let _ = write!(out, "{}", n as i64);
    } else if n.abs() >= 1e17 || n.abs() < 1e-5 {
        // Exponent form, e.g. 1e+20 or 1.5e-07.
        let s = format!("{:e}", n);
        let (mant, exp) = s.split_once('e').unwrap();
        let (sign, digits) = match exp.strip_prefix('-') {
            Some(d) => ('-', d),
            None => ('+', exp),
        };
        let _ = write!(out, "{}e{}{:0>2}", mant, sign, digits);
    } else {
        let _ = write!(out, "{}", n);
    }
}

impl Value {
    /// Appends the compact JSON text of this value to `out`.
    pub fn write_json(&self, out: &mut String) {
        match self {
            Value::Null => out.push_str("null"),
            Value::Bool(true) => out.push_str("true"),
            Value::Bool(false) => out.push_str("false"),
            Value::Number(n) => write_json_number(*n, out),
            Value::String(s) => write_json_string(s, out),
            Value::Array(a) => {
                out.push('[');
                for (i, v) in a.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    v.write_json(out);
                }
                out.push(']');
            }
            Value::Object(o) => {
                out.push('{');
                for (i, (k, v)) in o.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write_json_string(k, out);
                    out.push(':');
                    v.write_json(out);
                }
                out.push('}');
            }
        }
    }

    /// Returns the compact JSON text of this value.
    pub fn to_json(&self) -> String {
        let mut s = String::new();
        self.write_json(&mut s);
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rt(s: &str) -> String {
        Value::parse_json(s).unwrap().to_json()
    }

    #[test]
    fn roundtrip_basic() {
        assert_eq!(rt(" [1, 2.5 ,\"a\" , null,true,false,{\"k\" : {}}] "), "[1,2.5,\"a\",null,true,false,{\"k\":{}}]");
        assert_eq!(rt("-12"), "-12");
        assert_eq!(rt("3086419725308.5"), "3086419725308.5");
        assert_eq!(rt("1000000000000"), "1000000000000");
    }

    #[test]
    fn string_escapes() {
        assert_eq!(rt(r#""A😀\/\b\f""#), "\"A\u{1F600}/\\b\\f\"");
        assert_eq!(rt(r#""\u007f\u0001""#), "\"\\u007f\\u0001\"");
        assert_eq!(rt("\"é<>&\""), "\"é<>&\"");
    }

    #[test]
    fn key_order_kept() {
        assert_eq!(rt(r#"{"z":1,"a":2,"m":3}"#), r#"{"z":1,"a":2,"m":3}"#);
    }

    #[test]
    fn errors() {
        assert!(Value::parse_json("").is_err());
        assert!(Value::parse_json("[1,]").is_err());
        assert!(Value::parse_json("01").is_err());
        assert!(Value::parse_json("1 2").is_err());
        assert!(Value::parse_json("\"abc").is_err());
        assert!(Value::parse_json("{\"a\" 1}").is_err());
    }

    #[test]
    fn number_formats() {
        let f = |n: f64| {
            let mut s = String::new();
            write_json_number(n, &mut s);
            s
        };
        assert_eq!(f(0.125), "0.125");
        assert_eq!(f(-0.0), "-0");
        assert_eq!(f(1e20), "1e+20");
        assert_eq!(f(1.5e-7), "1.5e-07");
        assert_eq!(f(0.001), "0.001");
    }
}
