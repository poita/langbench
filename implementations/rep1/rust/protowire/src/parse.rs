//! Canonical (and relaxed) text → value tree, by recursive descent.

use crate::error::{Error, Result};
use crate::hex::digit_value;
use crate::schema::{FieldDesc, FieldKind, MessageId, ScalarType, Schema};
use crate::value::{FieldValue, Message, Value};

/// Guard against pathological recursion; the format never nests this deep.
const MAX_DEPTH: usize = 128;

impl Schema {
    /// Parses `text` — one text-form message, with optional spaces between
    /// tokens — as a message of type `id`.
    pub fn parse_text(&self, id: MessageId, text: &[u8]) -> Result<Message> {
        let mut p = Parser { schema: self, text, pos: 0 };
        p.skip_spaces();
        let msg = p.message(id, 0)?;
        p.skip_spaces();
        if p.pos != p.text.len() {
            return p.fail("trailing text after message");
        }
        Ok(msg)
    }
}

struct Parser<'a> {
    schema: &'a Schema,
    text: &'a [u8],
    pos: usize,
}

fn is_ident(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

impl<'a> Parser<'a> {
    fn fail<T>(&self, message: &'static str) -> Result<T> {
        Err(Error::Text { offset: self.pos, message })
    }

    #[inline]
    fn peek(&self) -> Option<u8> {
        self.text.get(self.pos).copied()
    }

    fn skip_spaces(&mut self) {
        while self.peek() == Some(b' ') {
            self.pos += 1;
        }
    }

    fn expect(&mut self, c: u8, message: &'static str) -> Result<()> {
        if self.peek() == Some(c) {
            self.pos += 1;
            Ok(())
        } else {
            self.fail(message)
        }
    }

    /// A maximal run of `[A-Za-z0-9_]`.
    fn word(&mut self) -> &'a [u8] {
        let start = self.pos;
        while self.peek().is_some_and(is_ident) {
            self.pos += 1;
        }
        &self.text[start..self.pos]
    }

    fn message(&mut self, id: MessageId, depth: usize) -> Result<Message> {
        if depth > MAX_DEPTH {
            return self.fail("nesting too deep");
        }
        let desc = self.schema.message(id);
        let mut msg = Message::new(desc.fields.len());
        self.expect(b'{', "expected `{`")?;
        self.skip_spaces();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(msg);
        }
        loop {
            self.skip_spaces();
            let name = self.word();
            let slot = std::str::from_utf8(name)
                .ok()
                .and_then(|n| desc.field_by_name(n))
                .ok_or(Error::Text { offset: self.pos, message: "unknown field name" })?;
            if msg.slots[slot].is_some() {
                return self.fail("field given twice");
            }
            self.skip_spaces();
            self.expect(b':', "expected `:`")?;
            self.skip_spaces();
            let value = self.field_value(&desc.fields[slot], depth)?;
            msg.slots[slot] = Some(value);
            self.skip_spaces();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(msg);
                }
                _ => return self.fail("expected `,` or `}`"),
            }
        }
    }

    fn field_value(&mut self, field: &FieldDesc, depth: usize) -> Result<FieldValue> {
        if !field.repeated {
            return Ok(FieldValue::Single(self.value(field.kind, depth)?));
        }
        self.expect(b'[', "expected list")?;
        let mut items = Vec::new();
        self.skip_spaces();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(FieldValue::List(items));
        }
        loop {
            self.skip_spaces();
            items.push(self.value(field.kind, depth)?);
            self.skip_spaces();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(FieldValue::List(items));
                }
                _ => return self.fail("expected `,` or `]`"),
            }
        }
    }

    fn value(&mut self, kind: FieldKind, depth: usize) -> Result<Value> {
        match kind {
            FieldKind::Message(id) => Ok(Value::Msg(self.message(id, depth + 1)?)),
            FieldKind::Scalar(ScalarType::Bool) => {
                match self.word() {
                    b"true" => Ok(Value::Num(1)),
                    b"false" => Ok(Value::Num(0)),
                    _ => self.fail("expected `true` or `false`"),
                }
            }
            FieldKind::Scalar(ScalarType::String) => {
                let bytes = self.string_literal()?;
                match String::from_utf8(bytes) {
                    Ok(s) => Ok(Value::Str(s)),
                    Err(_) => self.fail("string is not valid UTF-8"),
                }
            }
            FieldKind::Scalar(ScalarType::Bytes) => Ok(Value::Bytes(self.bytes_literal()?)),
            FieldKind::Scalar(t) => self.integer(t),
        }
    }

    fn integer(&mut self, t: ScalarType) -> Result<Value> {
        let (lo, hi) = t.int_range().expect("integer type");
        let negative = self.peek() == Some(b'-');
        if negative {
            self.pos += 1;
        }
        let start = self.pos;
        let mut mag: u128 = 0;
        while let Some(c @ b'0'..=b'9') = self.peek() {
            mag = mag * 10 + (c - b'0') as u128;
            if mag > u64::MAX as u128 + 1 {
                return self.fail("integer out of range");
            }
            self.pos += 1;
        }
        let digits = &self.text[start..self.pos];
        if digits.is_empty() {
            return self.fail("expected integer");
        }
        if digits.len() > 1 && digits[0] == b'0' {
            return self.fail("leading zero");
        }
        if negative && mag == 0 {
            return self.fail("negative zero");
        }
        let v = if negative { -(mag as i128) } else { mag as i128 };
        if v < lo || v > hi {
            return self.fail("integer out of range");
        }
        Ok(Value::Num(v as i64 as u64))
    }

    fn string_literal(&mut self) -> Result<Vec<u8>> {
        self.expect(b'"', "expected string")?;
        let mut out = Vec::new();
        loop {
            let Some(c) = self.peek() else {
                return self.fail("unterminated string");
            };
            self.pos += 1;
            match c {
                b'"' => return Ok(out),
                b'\\' => {
                    let Some(e) = self.peek() else {
                        return self.fail("unterminated string");
                    };
                    self.pos += 1;
                    match e {
                        b'"' => out.push(b'"'),
                        b'\\' => out.push(b'\\'),
                        b'n' => out.push(b'\n'),
                        b'r' => out.push(b'\r'),
                        b't' => out.push(b'\t'),
                        b'x' => {
                            let hi = self.peek().and_then(hex_digit_any_case);
                            let lo = self.text.get(self.pos + 1).copied().and_then(hex_digit_any_case);
                            match (hi, lo) {
                                (Some(h), Some(l)) => {
                                    self.pos += 2;
                                    out.push(h << 4 | l);
                                }
                                _ => return self.fail("bad \\x escape"),
                            }
                        }
                        _ => return self.fail("unknown escape"),
                    }
                }
                0..=0x1f => {
                    self.pos -= 1;
                    return self.fail("control character in string");
                }
                _ => out.push(c),
            }
        }
    }

    fn bytes_literal(&mut self) -> Result<Vec<u8>> {
        self.expect(b'x', "expected bytes literal")?;
        self.expect(b'"', "expected `\"` after `x`")?;
        let start = self.pos;
        while self.peek().is_some_and(|c| c != b'"') {
            self.pos += 1;
        }
        let digits = &self.text[start..self.pos];
        if self.peek() != Some(b'"') {
            return self.fail("unterminated bytes literal");
        }
        let bytes = crate::hex::decode(digits)
            .map_err(|_| Error::Text { offset: start, message: "bad hex in bytes literal" })?;
        self.pos += 1;
        Ok(bytes)
    }
}

fn hex_digit_any_case(c: u8) -> Option<u8> {
    digit_value(c.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: &str = "message I { int32 v = 1; } message M { int32 a = 1; uint32 u = 2; string s = 3; bytes y = 4; bool b = 5; repeated int32 c = 6; I d = 7; repeated I e = 8; int64 l = 9; uint64 ul = 10; }";

    fn ok(text: &str) -> bool {
        let s = Schema::parse(S).unwrap();
        s.parse_text(s.message_id("M").unwrap(), text.as_bytes()).is_ok()
    }

    #[test]
    fn accepts_relaxed_forms() {
        assert!(ok("{}"));
        assert!(ok("  {  }  "));
        assert!(ok("{a:1,c:[1,2]}"));
        assert!(ok("{ a : 1 , c : [ 1 , 2 ] }"));
        assert!(ok(r#"{s: "\xc3\xa9", y: x"", b: false, c: [], d: {}}"#));
        assert!(ok(r#"{s: "\"\\\n\r\t\xC3\xa9\x7f"}"#));
        assert!(ok("{e: [{}, {v: 1}], e2: 1}".replace(", e2: 1", "").as_str()));
        assert!(ok("{a: -2147483648}"));
        assert!(ok("{ul: 18446744073709551615}"));
    }

    #[test]
    fn rejects_bad_text() {
        for t in [
            "", "   ", "{", "{a: 1", "{a: 1}x", "{a: 1,}", "{,}", "{a 1}", "{a: }", "{a: 1 b: 2}",
            "{a: 1, a: 2}", "{a: 0, a: 0}", "{z: 1}", "{a: - 1}", "{a: +5}", "{a: 007}", "{a: -0}", "{a: 1.0}",
            "{a: 2147483648}", "{a: -2147483649}", "{u: -1}", "{u: 4294967296}", "{ul: 18446744073709551616}",
            "{l: 9223372036854775808}", "{b: True}", "{b: 1}", "{b: tr ue}", "{b: \"true\"}", "{s: 1}", "{a: \"1\"}",
            "{a: {}}", "{a: [1]}", "{c: 1}", "{c: [[1]]}", "{c: [1,]}", "{c: [1 2]}", "{d: 1}", "{d: []}",
            "{y: \"ab\"}", "{y: x\"0\"}", "{y: x\"0A\"}", "{y: x \"00\"}", "{s: \"\\q\"}", "{s: \"\\x4\"}",
            "{s: \"\\xff\"}", "{s: \"a\tb\"}", "{s: \"abc}", "{a:\t1}", "\t{}", "{a: 1}\t", "{a: 99999999999999999999999999999999999999999}",
        ] {
            assert!(!ok(t), "should reject {t:?}");
        }
    }
}
