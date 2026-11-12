//! JSON values and a strict RFC 8259 parser.
//!
//! Numbers are kept as exact decimals ([`Number`]); objects preserve member
//! order and offer O(1) lookup by name.

use crate::number::Number;
use std::collections::hash_map::DefaultHasher;
use std::collections::HashMap;
use std::fmt;
use std::hash::{Hash, Hasher};

/// Objects with more members than this get a hash index.
const INDEX_THRESHOLD: usize = 8;

/// Default maximum nesting depth accepted by [`parse`].
pub const MAX_DEPTH: usize = 100_000;

/// A JSON value.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Json {
    /// `null`
    Null,
    /// `true` or `false`
    Bool(bool),
    /// An exact decimal number.
    Number(Number),
    /// A string.
    String(String),
    /// An array.
    Array(Vec<Json>),
    /// An object.
    Object(Object),
}

impl Json {
    /// Returns the string if this is a JSON string.
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::String(s) => Some(s),
            _ => None,
        }
    }

    /// Returns the object if this is a JSON object.
    pub fn as_object(&self) -> Option<&Object> {
        match self {
            Json::Object(o) => Some(o),
            _ => None,
        }
    }

    /// Returns the elements if this is a JSON array.
    pub fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(a) => Some(a),
            _ => None,
        }
    }

    /// Returns the number if this is a JSON number.
    pub fn as_number(&self) -> Option<&Number> {
        match self {
            Json::Number(n) => Some(n),
            _ => None,
        }
    }

    /// Returns the boolean if this is a JSON boolean.
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(b) => Some(*b),
            _ => None,
        }
    }
}

impl Hash for Json {
    /// Hashes consistently with JSON equality (object member order and the
    /// spelling of numbers do not matter).
    fn hash<H: Hasher>(&self, state: &mut H) {
        match self {
            Json::Null => state.write_u8(0),
            Json::Bool(b) => {
                state.write_u8(1);
                b.hash(state);
            }
            Json::Number(n) => {
                state.write_u8(2);
                n.hash(state);
            }
            Json::String(s) => {
                state.write_u8(3);
                s.hash(state);
            }
            Json::Array(a) => {
                state.write_u8(4);
                state.write_usize(a.len());
                for v in a {
                    v.hash(state);
                }
            }
            Json::Object(o) => {
                state.write_u8(5);
                state.write_usize(o.len());
                let mut sum = 0u64;
                for (k, v) in o.iter() {
                    let mut h = DefaultHasher::new();
                    k.hash(&mut h);
                    v.hash(&mut h);
                    sum = sum.wrapping_add(h.finish());
                }
                state.write_u64(sum);
            }
        }
    }
}

/// A JSON object: members in document order with O(1) lookup by name.
#[derive(Clone, Debug, Default)]
pub struct Object {
    entries: Vec<(String, Json)>,
    index: Option<HashMap<String, usize>>,
}

impl Object {
    /// Creates an empty object.
    pub fn new() -> Self {
        Object::default()
    }

    /// Inserts a member, replacing the value of an existing member with the
    /// same name.
    pub fn insert(&mut self, key: String, value: Json) {
        if let Some(i) = self.position(&key) {
            self.entries[i].1 = value;
            return;
        }
        if let Some(idx) = &mut self.index {
            idx.insert(key.clone(), self.entries.len());
        }
        self.entries.push((key, value));
        if self.index.is_none() && self.entries.len() > INDEX_THRESHOLD {
            self.index = Some(
                self.entries
                    .iter()
                    .enumerate()
                    .map(|(i, (k, _))| (k.clone(), i))
                    .collect(),
            );
        }
    }

    /// The position of the member called `key`, in document order.
    pub fn position(&self, key: &str) -> Option<usize> {
        match &self.index {
            Some(idx) => idx.get(key).copied(),
            None => self.entries.iter().position(|(k, _)| k == key),
        }
    }

    /// The value of the member called `key`.
    pub fn get(&self, key: &str) -> Option<&Json> {
        self.position(key).map(|i| &self.entries[i].1)
    }

    /// Returns `true` if the object has a member called `key`.
    pub fn contains_key(&self, key: &str) -> bool {
        self.position(key).is_some()
    }

    /// Number of members.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Returns `true` if the object has no members.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Iterates over members in document order.
    pub fn iter(&self) -> impl Iterator<Item = (&str, &Json)> {
        self.entries.iter().map(|(k, v)| (k.as_str(), v))
    }

    /// The `i`-th member in document order.
    pub fn entry(&self, i: usize) -> (&str, &Json) {
        let (k, v) = &self.entries[i];
        (k, v)
    }
}

impl PartialEq for Object {
    fn eq(&self, other: &Self) -> bool {
        self.len() == other.len()
            && self
                .iter()
                .all(|(k, v)| other.get(k).is_some_and(|w| v == w))
    }
}

impl Eq for Object {}

/// An error produced while parsing JSON text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    /// What went wrong.
    pub message: String,
    /// Byte offset into the input.
    pub offset: usize,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "JSON parse error at byte {}: {}", self.offset, self.message)
    }
}

impl std::error::Error for ParseError {}

/// Parses a complete JSON document.
///
/// ```
/// let v = jsonschema::json::parse(r#"{"a": [1, 2.50, "x"]}"#).unwrap();
/// assert!(v.as_object().unwrap().contains_key("a"));
/// ```
pub fn parse(text: &str) -> Result<Json, ParseError> {
    parse_with_max_depth(text, MAX_DEPTH)
}

/// Like [`parse`] with an explicit nesting limit.
pub fn parse_with_max_depth(text: &str, max_depth: usize) -> Result<Json, ParseError> {
    let mut p = Parser {
        src: text,
        bytes: text.as_bytes(),
        pos: 0,
        max_depth,
    };
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
    max_depth: usize,
}

impl Parser<'_> {
    fn err(&self, message: &str) -> ParseError {
        ParseError {
            message: message.to_string(),
            offset: self.pos,
        }
    }

    fn skip_ws(&mut self) {
        while let Some(b' ' | b'\t' | b'\n' | b'\r') = self.bytes.get(self.pos) {
            self.pos += 1;
        }
    }

    fn expect_lit(&mut self, lit: &str, v: Json) -> Result<Json, ParseError> {
        if self.src[self.pos..].starts_with(lit) {
            self.pos += lit.len();
            Ok(v)
        } else {
            Err(self.err("invalid literal"))
        }
    }

    fn value(&mut self, depth: usize) -> Result<Json, ParseError> {
        if depth > self.max_depth {
            return Err(self.err("nesting too deep"));
        }
        match self.bytes.get(self.pos) {
            None => Err(self.err("unexpected end of input")),
            Some(b'n') => self.expect_lit("null", Json::Null),
            Some(b't') => self.expect_lit("true", Json::Bool(true)),
            Some(b'f') => self.expect_lit("false", Json::Bool(false)),
            Some(b'"') => Ok(Json::String(self.string()?)),
            Some(b'[') => self.array(depth),
            Some(b'{') => self.object(depth),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(_) => Err(self.err("unexpected character")),
        }
    }

    fn array(&mut self, depth: usize) -> Result<Json, ParseError> {
        self.pos += 1;
        let mut items = Vec::new();
        self.skip_ws();
        if self.bytes.get(self.pos) == Some(&b']') {
            self.pos += 1;
            return Ok(Json::Array(items));
        }
        loop {
            self.skip_ws();
            items.push(self.value(depth + 1)?);
            self.skip_ws();
            match self.bytes.get(self.pos) {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Json::Array(items));
                }
                _ => return Err(self.err("expected ',' or ']'")),
            }
        }
    }

    fn object(&mut self, depth: usize) -> Result<Json, ParseError> {
        self.pos += 1;
        let mut obj = Object::new();
        self.skip_ws();
        if self.bytes.get(self.pos) == Some(&b'}') {
            self.pos += 1;
            return Ok(Json::Object(obj));
        }
        loop {
            self.skip_ws();
            if self.bytes.get(self.pos) != Some(&b'"') {
                return Err(self.err("expected object key"));
            }
            let key = self.string()?;
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
                    return Ok(Json::Object(obj));
                }
                _ => return Err(self.err("expected ',' or '}'")),
            }
        }
    }

    fn number(&mut self) -> Result<Json, ParseError> {
        let start = self.pos;
        let b = self.bytes;
        let mut i = self.pos;
        if b.get(i) == Some(&b'-') {
            i += 1;
        }
        match b.get(i) {
            Some(b'0') => i += 1,
            Some(b'1'..=b'9') => {
                while b.get(i).is_some_and(u8::is_ascii_digit) {
                    i += 1;
                }
            }
            _ => return Err(self.err("invalid number")),
        }
        if b.get(i) == Some(&b'.') {
            i += 1;
            if !b.get(i).is_some_and(u8::is_ascii_digit) {
                self.pos = i;
                return Err(self.err("expected digit after '.'"));
            }
            while b.get(i).is_some_and(u8::is_ascii_digit) {
                i += 1;
            }
        }
        if let Some(b'e' | b'E') = b.get(i) {
            i += 1;
            if let Some(b'+' | b'-') = b.get(i) {
                i += 1;
            }
            if !b.get(i).is_some_and(u8::is_ascii_digit) {
                self.pos = i;
                return Err(self.err("expected digit in exponent"));
            }
            while b.get(i).is_some_and(u8::is_ascii_digit) {
                i += 1;
            }
        }
        self.pos = i;
        match Number::parse(&self.src[start..i]) {
            Some(n) => Ok(Json::Number(n)),
            None => Err(ParseError {
                message: "invalid number".to_string(),
                offset: start,
            }),
        }
    }

    fn hex4(&mut self) -> Result<u32, ParseError> {
        let end = self.pos + 4;
        let digits = self
            .src
            .get(self.pos..end)
            .ok_or_else(|| self.err("truncated \\u escape"))?;
        let v = u32::from_str_radix(digits, 16)
            .ok()
            .filter(|_| digits.bytes().all(|b| b.is_ascii_hexdigit()))
            .ok_or_else(|| self.err("invalid \\u escape"))?;
        self.pos = end;
        Ok(v)
    }

    fn string(&mut self) -> Result<String, ParseError> {
        self.pos += 1; // opening quote
        let start = self.pos;
        // Fast path: no escapes.
        loop {
            match self.bytes.get(self.pos) {
                None => return Err(self.err("unterminated string")),
                Some(b'"') => {
                    let s = self.src[start..self.pos].to_string();
                    self.pos += 1;
                    return Ok(s);
                }
                Some(b'\\') => break,
                Some(&c) if c < 0x20 => return Err(self.err("control character in string")),
                Some(_) => self.pos += 1,
            }
        }
        let mut out = String::from(&self.src[start..self.pos]);
        loop {
            // Copy a run of plain bytes.
            let run = self.pos;
            while let Some(&c) = self.bytes.get(self.pos) {
                if c == b'"' || c == b'\\' || c < 0x20 {
                    break;
                }
                self.pos += 1;
            }
            out.push_str(&self.src[run..self.pos]);
            match self.bytes.get(self.pos) {
                None => return Err(self.err("unterminated string")),
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.pos += 1;
                    let Some(&e) = self.bytes.get(self.pos) else {
                        return Err(self.err("unterminated escape"));
                    };
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
                                if !self.src[self.pos..].starts_with("\\u") {
                                    return Err(self.err("unpaired surrogate"));
                                }
                                self.pos += 2;
                                let lo = self.hex4()?;
                                if !(0xDC00..0xE000).contains(&lo) {
                                    return Err(self.err("unpaired surrogate"));
                                }
                                0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                            } else if (0xDC00..0xE000).contains(&hi) {
                                return Err(self.err("unpaired surrogate"));
                            } else {
                                hi
                            };
                            out.push(char::from_u32(cp).ok_or_else(|| self.err("bad code point"))?);
                        }
                        _ => return Err(self.err("invalid escape")),
                    }
                }
                Some(_) => return Err(self.err("control character in string")),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn parses_scalars() {
        assert_eq!(parse("null").unwrap(), Json::Null);
        assert_eq!(parse(" true ").unwrap(), Json::Bool(true));
        assert_eq!(parse("\"a\\n\\u00e9\"").unwrap(), Json::String("a\né".into()));
        assert_eq!(parse("1.50").unwrap(), parse("1.5").unwrap());
    }

    #[test]
    fn surrogate_pairs_combine() {
        assert_eq!(parse(r#""💩""#).unwrap(), Json::String("💩".into()));
        assert!(parse(r#""\ud83d""#).is_err());
        assert!(parse(r#""\udca9""#).is_err());
    }

    #[test]
    fn rejects_malformed() {
        for s in ["", "[1,]", "{\"a\"}", "01", "1.", "\"a", "[1 2]", "nul", "{} x", "-"] {
            assert!(parse(s).is_err(), "{s:?} should fail");
        }
    }

    #[test]
    fn object_equality_ignores_order_and_number_spelling() {
        let a = parse(r#"{"a":1,"b":[2.0]}"#).unwrap();
        let b = parse(r#"{"b":[2],"a":1.000}"#).unwrap();
        assert_eq!(a, b);
        let mut set = HashSet::new();
        set.insert(a);
        assert!(!set.insert(b));
    }

    #[test]
    fn types_are_never_equal() {
        assert_ne!(parse("true").unwrap(), parse("1").unwrap());
        assert_ne!(parse("\"1\"").unwrap(), parse("1").unwrap());
        assert_ne!(parse("[]").unwrap(), parse("{}").unwrap());
    }

    #[test]
    fn large_objects_use_an_index() {
        let body: Vec<String> = (0..50).map(|i| format!("\"k{i}\":{i}")).collect();
        let v = parse(&format!("{{{}}}", body.join(","))).unwrap();
        let o = v.as_object().unwrap();
        assert_eq!(o.len(), 50);
        assert_eq!(o.position("k37"), Some(37));
        assert!(o.get("missing").is_none());
    }

    #[test]
    fn depth_limit() {
        let deep = format!("{}{}", "[".repeat(50), "]".repeat(50));
        assert!(parse_with_max_depth(&deep, 10).is_err());
        assert!(parse_with_max_depth(&deep, 100).is_ok());
    }
}
