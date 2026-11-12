//! Value tree → canonical text.

use std::fmt::Write;

use crate::error::{Error, Result};
use crate::hex;
use crate::schema::{FieldKind, MessageId, ScalarType, Schema};
use crate::value::{FieldValue, Message, Value};

impl Schema {
    /// Renders a value tree of message type `id` in canonical text form.
    pub fn render(&self, id: MessageId, msg: &Message) -> String {
        let mut out = String::new();
        render_message(self, id, msg, &mut out);
        out
    }

    /// Decodes `bytes` as the message named `message` and renders it in
    /// canonical text form.
    ///
    /// ```
    /// let schema = protowire::Schema::parse("message A { int32 x = 1; }").unwrap();
    /// assert_eq!(schema.decode_to_text("A", &[0x08, 0x2a]).unwrap(), "{x: 42}");
    /// ```
    pub fn decode_to_text(&self, message: &str, bytes: &[u8]) -> Result<String> {
        let id = self
            .message_id(message)
            .ok_or_else(|| Error::UnknownMessage(message.to_owned()))?;
        let msg = self.decode(id, bytes)?;
        Ok(self.render(id, &msg))
    }
}

pub(crate) fn render_message(schema: &Schema, id: MessageId, msg: &Message, out: &mut String) {
    let desc = schema.message(id);
    out.push('{');
    let mut first = true;
    for (field, slot) in desc.fields.iter().zip(&msg.slots) {
        let Some(fv) = slot else { continue };
        match fv {
            FieldValue::Single(v) => {
                if is_default(v) {
                    continue;
                }
                begin_field(out, &mut first, &field.name);
                render_value(schema, field.kind, v, out);
            }
            FieldValue::List(vs) => {
                if vs.is_empty() {
                    continue;
                }
                begin_field(out, &mut first, &field.name);
                out.push('[');
                for (i, v) in vs.iter().enumerate() {
                    if i > 0 {
                        out.push_str(", ");
                    }
                    render_value(schema, field.kind, v, out);
                }
                out.push(']');
            }
        }
    }
    out.push('}');
}

fn begin_field(out: &mut String, first: &mut bool, name: &str) {
    if !*first {
        out.push_str(", ");
    }
    *first = false;
    out.push_str(name);
    out.push_str(": ");
}

/// Whether a singular value is the omitted default (messages never are).
fn is_default(v: &Value) -> bool {
    match v {
        Value::Num(n) => *n == 0,
        Value::Str(s) => s.is_empty(),
        Value::Bytes(b) => b.is_empty(),
        Value::Msg(_) => false,
    }
}

fn render_value(schema: &Schema, kind: FieldKind, v: &Value, out: &mut String) {
    match (kind, v) {
        (FieldKind::Scalar(t), Value::Num(n)) => render_num(t, *n, out),
        (_, Value::Str(s)) => render_string(s, out),
        (_, Value::Bytes(b)) => {
            out.push_str("x\"");
            hex::encode_into(b, out);
            out.push('"');
        }
        (FieldKind::Message(id), Value::Msg(m)) => render_message(schema, id, m, out),
        _ => unreachable!("value does not match its field type"),
    }
}

fn render_num(t: ScalarType, n: u64, out: &mut String) {
    if t == ScalarType::Bool {
        out.push_str(if n != 0 { "true" } else { "false" });
    } else if t.is_signed() {
        let _ = write!(out, "{}", n as i64);
    } else {
        let _ = write!(out, "{n}");
    }
}

/// Appends `s` as a quoted, escaped string literal.
pub(crate) fn render_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 || c == '\x7f' => {
                let _ = write!(out, "\\x{:02x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes() {
        let mut s = String::new();
        render_string("a\"b\\c\nd\re\tf\x00\x1f\x7fé😀", &mut s);
        assert_eq!(s, "\"a\\\"b\\\\c\\nd\\re\\tf\\x00\\x1f\\x7fé😀\"");
    }

    #[test]
    fn signedness() {
        let mut s = String::new();
        render_num(ScalarType::Sfixed32, 0xffff_ffff_ffff_ffff, &mut s);
        s.push(' ');
        render_num(ScalarType::Fixed32, 0xffff_ffff, &mut s);
        assert_eq!(s, "-1 4294967295");
    }
}
