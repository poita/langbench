//! Value tree → wire bytes.
//!
//! Encoding is two linear passes: [`measure`] computes the encoded size of
//! every message node exactly once (caching it in the node), then [`write`]
//! emits the bytes into a single buffer using the cached sizes.

use crate::error::{Error, Result};
use crate::hex;
use crate::schema::{FieldKind, MessageId, ScalarType, Schema};
use crate::value::{FieldValue, Message, Value};
use crate::wire::{put_tag, put_varint, tag_value, varint_len, zigzag32, zigzag64, WireType};

impl Schema {
    /// Encodes a value tree of message type `id` in canonical form.
    pub fn encode(&self, id: MessageId, msg: &Message) -> Vec<u8> {
        let total = measure(self, id, msg);
        let mut out = Vec::with_capacity(total);
        write(self, id, msg, &mut out);
        debug_assert_eq!(out.len(), total);
        out
    }

    /// Parses `text` as a text-form message of type `message` and encodes it.
    ///
    /// ```
    /// let schema = protowire::Schema::parse("message A { int32 x = 1; }").unwrap();
    /// assert_eq!(schema.encode_from_text("A", "{x: 42}").unwrap(), [0x08, 0x2a]);
    /// ```
    pub fn encode_from_text(&self, message: &str, text: &str) -> Result<Vec<u8>> {
        let id = self
            .message_id(message)
            .ok_or_else(|| Error::UnknownMessage(message.to_owned()))?;
        let msg = self.parse_text(id, text.as_bytes())?;
        Ok(self.encode(id, &msg))
    }

    /// Like [`Schema::encode_from_text`] but returns lowercase hex.
    pub fn encode_to_hex(&self, message: &str, text: &str) -> Result<String> {
        Ok(hex::encode(&self.encode_from_text(message, text)?))
    }
}

/// Whether a singular value is omitted from the encoding.
fn is_default(v: &Value) -> bool {
    match v {
        Value::Num(n) => *n == 0,
        Value::Str(s) => s.is_empty(),
        Value::Bytes(b) => b.is_empty(),
        Value::Msg(_) => false,
    }
}

/// Size in bytes of one numeric element's value encoding.
#[inline]
fn num_len(t: ScalarType, n: u64) -> usize {
    match t {
        ScalarType::Fixed32 | ScalarType::Sfixed32 => 4,
        ScalarType::Fixed64 | ScalarType::Sfixed64 => 8,
        _ => varint_len(varint_bits(t, n)),
    }
}

/// The varint payload of a varint-typed value.
#[inline]
fn varint_bits(t: ScalarType, n: u64) -> u64 {
    match t {
        ScalarType::Sint32 => zigzag32(n as i32) as u64,
        ScalarType::Sint64 => zigzag64(n as i64),
        _ => n,
    }
}

#[inline]
fn put_num(out: &mut Vec<u8>, t: ScalarType, n: u64) {
    match t {
        ScalarType::Fixed32 | ScalarType::Sfixed32 => out.extend_from_slice(&(n as u32).to_le_bytes()),
        ScalarType::Fixed64 | ScalarType::Sfixed64 => out.extend_from_slice(&n.to_le_bytes()),
        _ => put_varint(out, varint_bits(t, n)),
    }
}

/// Size of a length-delimited field: tag + length prefix + payload.
#[inline]
fn len_field_size(tag_len: usize, payload: usize) -> usize {
    tag_len + varint_len(payload as u64) + payload
}

fn packed_payload_len(t: ScalarType, vs: &[Value]) -> usize {
    match t {
        ScalarType::Fixed32 | ScalarType::Sfixed32 => vs.len() * 4,
        ScalarType::Fixed64 | ScalarType::Sfixed64 => vs.len() * 8,
        _ => vs
            .iter()
            .map(|v| match v {
                Value::Num(n) => num_len(t, *n),
                _ => unreachable!(),
            })
            .sum(),
    }
}

/// Computes (and caches in each node) the encoded size of `msg`.
fn measure(schema: &Schema, id: MessageId, msg: &Message) -> usize {
    let desc = schema.message(id);
    let mut total = 0;
    for (field, slot) in desc.fields.iter().zip(&msg.slots) {
        let Some(fv) = slot else { continue };
        match (fv, field.kind) {
            (FieldValue::Single(v), kind) => {
                if is_default(v) {
                    continue;
                }
                total += value_size(schema, field.number, kind, v);
            }
            (FieldValue::List(vs), FieldKind::Scalar(t)) if t.is_numeric() => {
                if vs.is_empty() {
                    continue;
                }
                let tag_len = varint_len(tag_value(field.number, WireType::Len));
                total += len_field_size(tag_len, packed_payload_len(t, vs));
            }
            (FieldValue::List(vs), kind) => {
                for v in vs {
                    total += value_size(schema, field.number, kind, v);
                }
            }
        }
    }
    msg.encoded_len.set(total);
    total
}

/// Size of one field occurrence (tag + value) for a non-packed value.
fn value_size(schema: &Schema, number: u32, kind: FieldKind, v: &Value) -> usize {
    let tag = |w| varint_len(tag_value(number, w));
    match (kind, v) {
        (FieldKind::Scalar(t), Value::Num(n)) => tag(t.wire_type()) + num_len(t, *n),
        (_, Value::Str(s)) => len_field_size(tag(WireType::Len), s.len()),
        (_, Value::Bytes(b)) => len_field_size(tag(WireType::Len), b.len()),
        (FieldKind::Message(sub), Value::Msg(m)) => {
            len_field_size(tag(WireType::Len), measure(schema, sub, m))
        }
        _ => unreachable!("value does not match its field type"),
    }
}

/// Writes `msg`, which must have been measured.
fn write(schema: &Schema, id: MessageId, msg: &Message, out: &mut Vec<u8>) {
    let desc = schema.message(id);
    for (field, slot) in desc.fields.iter().zip(&msg.slots) {
        let Some(fv) = slot else { continue };
        match (fv, field.kind) {
            (FieldValue::Single(v), kind) => {
                if !is_default(v) {
                    write_value(schema, field.number, kind, v, out);
                }
            }
            (FieldValue::List(vs), FieldKind::Scalar(t)) if t.is_numeric() => {
                if vs.is_empty() {
                    continue;
                }
                put_tag(out, field.number, WireType::Len);
                put_varint(out, packed_payload_len(t, vs) as u64);
                for v in vs {
                    if let Value::Num(n) = v {
                        put_num(out, t, *n);
                    }
                }
            }
            (FieldValue::List(vs), kind) => {
                for v in vs {
                    write_value(schema, field.number, kind, v, out);
                }
            }
        }
    }
}

fn write_value(schema: &Schema, number: u32, kind: FieldKind, v: &Value, out: &mut Vec<u8>) {
    match (kind, v) {
        (FieldKind::Scalar(t), Value::Num(n)) => {
            put_tag(out, number, t.wire_type());
            put_num(out, t, *n);
        }
        (_, Value::Str(s)) => {
            put_tag(out, number, WireType::Len);
            put_varint(out, s.len() as u64);
            out.extend_from_slice(s.as_bytes());
        }
        (_, Value::Bytes(b)) => {
            put_tag(out, number, WireType::Len);
            put_varint(out, b.len() as u64);
            out.extend_from_slice(b);
        }
        (FieldKind::Message(sub), Value::Msg(m)) => {
            put_tag(out, number, WireType::Len);
            put_varint(out, m.encoded_len.get() as u64);
            write(schema, sub, m, out);
        }
        _ => unreachable!("value does not match its field type"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: &str = "message I { sint32 v = 1; } message O { int32 a = 1; string b = 2; repeated int32 c = 3; I d = 4; repeated string t = 5; repeated I m = 6; sfixed64 q = 7; }";

    fn enc(text: &str) -> Result<String> {
        Schema::parse(S).unwrap().encode_to_hex("O", text)
    }

    #[test]
    fn spec_examples() {
        assert_eq!(enc(r#"{a: 1, b: "x", c: [1, 2], d: {v: -5}}"#).unwrap(), "08011201781a02010222020809");
        assert_eq!(enc("{d: {}, c: [], a: 0}").unwrap(), "2200");
        assert_eq!(enc("{}").unwrap(), "");
    }

    #[test]
    fn defaults_in_lists_are_kept() {
        assert_eq!(enc("{c: [0, 0]}").unwrap(), "1a020000");
        assert_eq!(enc(r#"{t: ["", "a"]}"#).unwrap(), "2a002a0161");
        assert_eq!(enc("{m: [{}, {v: 1}]}").unwrap(), "320032020802");
    }

    #[test]
    fn negative_int32_is_ten_bytes() {
        assert_eq!(enc("{a: -1}").unwrap(), "08ffffffffffffffffff01");
        assert_eq!(enc("{q: -1}").unwrap(), "39ffffffffffffffff");
    }

    #[test]
    fn deep_nesting_is_linear() {
        // Each level nests the next; sizes are computed once per node.
        let s = Schema::parse("message N { N n = 1; int32 v = 2; }").unwrap();
        let depth = 60;
        let text = format!("{}{{v: 7}}{}", "{n: ".repeat(depth), "}".repeat(depth));
        let bytes = s.encode_from_text("N", &text).unwrap();
        assert_eq!(s.decode_to_text("N", &bytes).unwrap().replace(' ', ""), text.replace(' ', ""));
    }
}
