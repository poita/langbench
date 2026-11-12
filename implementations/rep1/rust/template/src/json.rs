//! A small recursive-descent JSON parser producing [`Value`]s.
//!
//! Numbers without a fraction or exponent are integers; others are floats.
//! Objects keep their member order.

use crate::error::{Error, Result};
use crate::value::{Dict, Value};
use std::rc::Rc;

/// Parses a complete JSON document.
pub fn parse(text: &str) -> Result<Value> {
    let mut p = JsonParser { s: text.as_bytes(), text, pos: 0 };
    p.skip_ws();
    let v = p.value()?;
    p.skip_ws();
    if p.pos != p.s.len() {
        return Err(p.err("trailing characters after JSON value"));
    }
    Ok(v)
}

struct JsonParser<'a> {
    s: &'a [u8],
    text: &'a str,
    pos: usize,
}

impl<'a> JsonParser<'a> {
    fn err(&self, msg: &str) -> Error {
        Error::syntax(format!("invalid JSON at byte {}: {}", self.pos, msg))
    }

    fn skip_ws(&mut self) {
        while matches!(self.s.get(self.pos), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.pos += 1;
        }
    }

    fn eat(&mut self, b: u8) -> bool {
        if self.s.get(self.pos) == Some(&b) {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn literal(&mut self, word: &str, v: Value) -> Result<Value> {
        if self.s[self.pos..].starts_with(word.as_bytes()) {
            self.pos += word.len();
            Ok(v)
        } else {
            Err(self.err("invalid literal"))
        }
    }

    fn value(&mut self) -> Result<Value> {
        match self.s.get(self.pos) {
            None => Err(self.err("unexpected end")),
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => Ok(Value::Str(Rc::from(self.string()?))),
            Some(b't') => self.literal("true", Value::Bool(true)),
            Some(b'f') => self.literal("false", Value::Bool(false)),
            Some(b'n') => self.literal("null", Value::None),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(_) => Err(self.err("unexpected character")),
        }
    }

    fn object(&mut self) -> Result<Value> {
        self.pos += 1;
        let mut dict = Dict::new();
        self.skip_ws();
        if self.eat(b'}') {
            return Ok(Value::dict(dict));
        }
        loop {
            self.skip_ws();
            if self.s.get(self.pos) != Some(&b'"') {
                return Err(self.err("expected string key"));
            }
            let key = self.string()?;
            self.skip_ws();
            if !self.eat(b':') {
                return Err(self.err("expected ':'"));
            }
            self.skip_ws();
            let v = self.value()?;
            dict.insert(Rc::from(key), v);
            self.skip_ws();
            if self.eat(b',') {
                continue;
            }
            if self.eat(b'}') {
                return Ok(Value::dict(dict));
            }
            return Err(self.err("expected ',' or '}'"));
        }
    }

    fn array(&mut self) -> Result<Value> {
        self.pos += 1;
        let mut items = Vec::new();
        self.skip_ws();
        if self.eat(b']') {
            return Ok(Value::list(items));
        }
        loop {
            self.skip_ws();
            items.push(self.value()?);
            self.skip_ws();
            if self.eat(b',') {
                continue;
            }
            if self.eat(b']') {
                return Ok(Value::list(items));
            }
            return Err(self.err("expected ',' or ']'"));
        }
    }

    fn number(&mut self) -> Result<Value> {
        let start = self.pos;
        self.eat(b'-');
        let digits = |p: &mut Self| {
            let s = p.pos;
            while matches!(p.s.get(p.pos), Some(b'0'..=b'9')) {
                p.pos += 1;
            }
            p.pos - s
        };
        if digits(self) == 0 {
            return Err(self.err("expected digits"));
        }
        let mut is_float = false;
        if self.eat(b'.') {
            is_float = true;
            if digits(self) == 0 {
                return Err(self.err("expected digits after '.'"));
            }
        }
        if matches!(self.s.get(self.pos), Some(b'e' | b'E')) {
            is_float = true;
            self.pos += 1;
            if matches!(self.s.get(self.pos), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            if digits(self) == 0 {
                return Err(self.err("expected exponent digits"));
            }
        }
        let t = &self.text[start..self.pos];
        if !is_float {
            if let Ok(i) = t.parse::<i64>() {
                return Ok(Value::Int(i));
            }
        }
        t.parse::<f64>().map(Value::Float).map_err(|_| self.err("bad number"))
    }

    fn hex4(&mut self) -> Result<u32> {
        let h = self.text.get(self.pos..self.pos + 4).ok_or_else(|| self.err("bad \\u escape"))?;
        let n = u32::from_str_radix(h, 16).map_err(|_| self.err("bad \\u escape"))?;
        self.pos += 4;
        Ok(n)
    }

    fn string(&mut self) -> Result<String> {
        self.pos += 1; // opening quote
        let mut out = String::new();
        loop {
            // Copy a run of ordinary characters at once.
            let start = self.pos;
            while let Some(&b) = self.s.get(self.pos) {
                if b == b'"' || b == b'\\' || b < 0x20 {
                    break;
                }
                self.pos += 1;
            }
            out.push_str(&self.text[start..self.pos]);
            match self.s.get(self.pos) {
                None => return Err(self.err("unterminated string")),
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.pos += 1;
                    let c = *self.s.get(self.pos).ok_or_else(|| self.err("bad escape"))?;
                    self.pos += 1;
                    match c {
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
                                if self.s[self.pos..].starts_with(b"\\u") {
                                    self.pos += 2;
                                    let lo = self.hex4()?;
                                    0x10000 + ((hi - 0xD800) << 10) + (lo.wrapping_sub(0xDC00) & 0x3FF)
                                } else {
                                    0xFFFD
                                }
                            } else {
                                hi
                            };
                            out.push(char::from_u32(cp).unwrap_or('\u{FFFD}'));
                        }
                        _ => return Err(self.err("bad escape")),
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

    #[test]
    fn numbers_ints_and_floats() {
        let v = parse(r#"[1, -2, 1.5, 1e2, 0]"#).unwrap();
        let Value::List(l) = v else { panic!() };
        assert!(matches!(l[0], Value::Int(1)));
        assert!(matches!(l[1], Value::Int(-2)));
        assert!(matches!(l[2], Value::Float(f) if f == 1.5));
        assert!(matches!(l[3], Value::Float(f) if f == 100.0));
        assert!(matches!(l[4], Value::Int(0)));
    }

    #[test]
    fn strings_and_escapes() {
        let v = parse(r#""a\nbé😀""#).unwrap();
        let Value::Str(s) = v else { panic!() };
        assert_eq!(&*s, "a\nbé😀");
    }

    #[test]
    fn object_order_is_preserved() {
        let Value::Dict(d) = parse(r#"{"z": 1, "a": null, "m": true}"#).unwrap() else { panic!() };
        let keys: Vec<&str> = d.keys().map(|k| &**k).collect();
        assert_eq!(keys, ["z", "a", "m"]);
    }

    #[test]
    fn rejects_garbage() {
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "01x", "\"abc", "[1] 2"] {
            assert!(parse(bad).is_err(), "{bad:?}");
        }
    }
}
