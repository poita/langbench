//! Wire bytes → value tree.

use crate::error::{Error, Result};
use crate::schema::{FieldDesc, FieldKind, MessageDesc, MessageId, ScalarType, Schema};
use crate::value::{FieldValue, Message, Value};
use crate::wire::{unzigzag32, unzigzag64, Reader, WireType};

/// Guard against pathological recursion. The format's limits keep real inputs
/// far below this.
const MAX_DEPTH: usize = 128;

impl Schema {
    /// Decodes `bytes` as a message of type `id` into a value tree.
    ///
    /// Unknown fields are skipped, a field with the wrong wire type is
    /// treated as unknown, repeated numeric fields accept packed and unpacked
    /// encodings, and repeated occurrences of a sub-message are merged.
    pub fn decode(&self, id: MessageId, bytes: &[u8]) -> Result<Message> {
        let desc = self.message(id);
        let mut msg = Message::new(desc.fields.len());
        decode_into(self, desc, &mut Reader::new(bytes), &mut msg, 0)?;
        Ok(msg)
    }
}

fn decode_into(
    schema: &Schema,
    desc: &MessageDesc,
    r: &mut Reader<'_>,
    msg: &mut Message,
    depth: usize,
) -> Result<()> {
    if depth > MAX_DEPTH {
        return Err(Error::Wire("nesting too deep"));
    }
    while !r.is_empty() {
        let tag = r.read_tag()?;
        if tag.wire == WireType::EndGroup {
            return Err(Error::Wire("end group outside a group"));
        }
        let Some(slot) = desc.field_by_number(tag.number) else {
            r.skip_field(tag)?;
            continue;
        };
        let field = &desc.fields[slot];
        match field.kind {
            FieldKind::Message(sub) => {
                if tag.wire != WireType::Len {
                    r.skip_field(tag)?;
                    continue;
                }
                let payload = r.read_len_delimited()?;
                decode_submessage(schema, field, sub, slot, payload, msg, depth)?;
            }
            FieldKind::Scalar(t) => {
                if tag.wire == t.wire_type() {
                    let v = read_scalar(r, t)?;
                    store(msg, slot, field.repeated, v);
                } else if tag.wire == WireType::Len && field.repeated && t.is_numeric() {
                    let payload = r.read_len_delimited()?;
                    read_packed(payload, t, msg, slot)?;
                } else {
                    r.skip_field(tag)?;
                }
            }
        }
    }
    Ok(())
}

fn decode_submessage(
    schema: &Schema,
    field: &FieldDesc,
    sub: MessageId,
    slot: usize,
    payload: &[u8],
    msg: &mut Message,
    depth: usize,
) -> Result<()> {
    let sub_desc = schema.message(sub);
    let mut reader = Reader::new(payload);
    if field.repeated {
        let mut m = Message::new(sub_desc.fields.len());
        decode_into(schema, sub_desc, &mut reader, &mut m, depth + 1)?;
        store(msg, slot, true, Value::Msg(m));
    } else if let Some(FieldValue::Single(Value::Msg(existing))) = &mut msg.slots[slot] {
        // A later occurrence of a singular message field merges into the earlier one.
        decode_into(schema, sub_desc, &mut reader, existing, depth + 1)?;
    } else {
        let mut m = Message::new(sub_desc.fields.len());
        decode_into(schema, sub_desc, &mut reader, &mut m, depth + 1)?;
        msg.slots[slot] = Some(FieldValue::Single(Value::Msg(m)));
    }
    Ok(())
}

#[inline]
fn store(msg: &mut Message, slot: usize, repeated: bool, v: Value) {
    if repeated {
        match &mut msg.slots[slot] {
            Some(FieldValue::List(list)) => list.push(v),
            s => *s = Some(FieldValue::List(vec![v])),
        }
    } else {
        msg.slots[slot] = Some(FieldValue::Single(v));
    }
}

/// Converts a raw varint to the normalised `Num` form for type `t`.
#[inline]
fn from_varint(t: ScalarType, v: u64) -> u64 {
    match t {
        ScalarType::Int32 => v as u32 as i32 as i64 as u64,
        ScalarType::Int64 | ScalarType::Uint64 => v,
        ScalarType::Uint32 => v & 0xffff_ffff,
        ScalarType::Sint32 => unzigzag32(v as u32) as i64 as u64,
        ScalarType::Sint64 => unzigzag64(v) as u64,
        ScalarType::Bool => (v != 0) as u64,
        _ => unreachable!("not a varint type"),
    }
}

#[inline]
fn read_scalar(r: &mut Reader<'_>, t: ScalarType) -> Result<Value> {
    use ScalarType::*;
    Ok(match t {
        Int32 | Int64 | Uint32 | Uint64 | Sint32 | Sint64 | Bool => {
            Value::Num(from_varint(t, r.read_varint()?))
        }
        Fixed32 => Value::Num(r.read_fixed32()? as u64),
        Sfixed32 => Value::Num(r.read_fixed32()? as i32 as i64 as u64),
        Fixed64 | Sfixed64 => Value::Num(r.read_fixed64()?),
        String => {
            let payload = r.read_len_delimited()?;
            let s = std::str::from_utf8(payload).map_err(|_| Error::Wire("invalid UTF-8"))?;
            Value::Str(s.to_owned())
        }
        Bytes => Value::Bytes(r.read_len_delimited()?.to_vec()),
    })
}

/// Appends the elements of a packed payload to the repeated field in `slot`.
fn read_packed(payload: &[u8], t: ScalarType, msg: &mut Message, slot: usize) -> Result<()> {
    let list = match &mut msg.slots[slot] {
        Some(FieldValue::List(list)) => list,
        s => {
            *s = Some(FieldValue::List(Vec::new()));
            match s {
                Some(FieldValue::List(list)) => list,
                _ => unreachable!(),
            }
        }
    };
    let mut r = Reader::new(payload);
    match t.wire_type() {
        WireType::Fixed32 => {
            if payload.len() % 4 != 0 {
                return Err(Error::Wire("packed fixed32 length not a multiple of 4"));
            }
            list.reserve(payload.len() / 4);
        }
        WireType::Fixed64 => {
            if payload.len() % 8 != 0 {
                return Err(Error::Wire("packed fixed64 length not a multiple of 8"));
            }
            list.reserve(payload.len() / 8);
        }
        _ => {}
    }
    while !r.is_empty() {
        list.push(read_scalar(&mut r, t)?);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hex;

    fn dec(schema: &str, msg: &str, hex_in: &str) -> Result<String> {
        let s = Schema::parse(schema).unwrap();
        s.decode_to_text(msg, &hex::decode(hex_in.as_bytes()).unwrap())
    }

    const S: &str = "message I { sint32 v = 1; } message O { int32 a = 1; string b = 2; repeated int32 c = 3; I d = 4; repeated fixed32 f = 5; }";

    #[test]
    fn spec_example() {
        assert_eq!(dec(S, "O", "08011201781a02010222020809").unwrap(), r#"{a: 1, b: "x", c: [1, 2], d: {v: -5}}"#);
        assert_eq!(dec(S, "O", "3800").unwrap(), "{}");
        assert!(dec(S, "O", "08ff").is_err());
    }

    #[test]
    fn packed_and_unpacked_mix() {
        assert_eq!(dec(S, "O", "1a0201021803 1a00".replace(' ', "").as_str()).unwrap(), "{c: [1, 2, 3]}");
        assert!(dec(S, "O", "1a0180").is_err());
        assert!(dec(S, "O", "2a03000000").is_err());
        assert_eq!(dec(S, "O", "2a0401000000").unwrap(), "{f: [1]}");
        assert_eq!(dec(S, "O", "2d01000000").unwrap(), "{f: [1]}");
    }

    #[test]
    fn wrong_wire_type_is_skipped() {
        assert_eq!(dec(S, "O", "0d00000000").unwrap(), "{}");
        assert_eq!(dec(S, "O", "100108 05".replace(' ', "").as_str()).unwrap(), "{a: 5}");
    }

    #[test]
    fn submessages_merge() {
        let s = "message P { repeated int32 r = 1; P p = 2; }";
        assert_eq!(dec(s, "P", "0801080212020803120208 04".replace(' ', "").as_str()).unwrap(), "{r: [1, 2], p: {r: [3, 4]}}");
        assert_eq!(dec(s, "P", "1200").unwrap(), "{p: {}}");
    }

    #[test]
    fn groups() {
        let s = "message P { repeated int32 r = 1; string s = 3; }";
        assert_eq!(dec(s, "P", "1b08011c0805").unwrap(), "{r: [5]}");
        assert!(dec(s, "P", "1b08011400").is_err());
        assert!(dec(s, "P", "1c").is_err());
        assert!(dec(s, "P", "1b0801").is_err());
    }

    #[test]
    fn invalid_utf8_rejected() {
        assert!(dec("message M { string s = 1; }", "M", "0a01ff").is_err());
        assert!(dec("message M { string s = 1; }", "M", "0a02c080").is_err());
        assert!(dec("message M { string s = 1; }", "M", "0a03eda080").is_err());
        assert_eq!(dec("message M { string s = 1; }", "M", "0a0100").unwrap(), r#"{s: "\x00"}"#);
    }
}
