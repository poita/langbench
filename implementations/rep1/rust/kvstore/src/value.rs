//! The document value model: six kinds of value, their binary serialisation,
//! canonical one-line rendering, deep comparison and path access.

use std::collections::BTreeMap;

use crate::error::{Error, Result};

/// A document value.
///
/// Objects are sets of fields held in ascending byte-wise order of their
/// names (a `BTreeMap<String, _>` iterates in exactly that order), so two
/// objects built in different orders are equal and serialise identically.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Value {
    /// `null` (rank 0).
    Null,
    /// `false` / `true` (rank 1).
    Bool(bool),
    /// A signed 64-bit integer (rank 2).
    Int(i64),
    /// A string (rank 3).
    Str(String),
    /// An ordered list (rank 4).
    List(Vec<Value>),
    /// An object (rank 5).
    Object(BTreeMap<String, Value>),
}

impl Value {
    /// The type rank used by comparisons and index keys (0 = null … 5 = object).
    pub fn rank(&self) -> u8 {
        match self {
            Value::Null => 0,
            Value::Bool(_) => 1,
            Value::Int(_) => 2,
            Value::Str(_) => 3,
            Value::List(_) => 4,
            Value::Object(_) => 5,
        }
    }

    /// Nesting depth: 1 for scalars and empty containers, otherwise one more
    /// than the deepest element.
    pub fn depth(&self) -> usize {
        match self {
            Value::List(items) => 1 + items.iter().map(Value::depth).max().unwrap_or(0),
            Value::Object(fields) => 1 + fields.values().map(Value::depth).max().unwrap_or(0),
            _ => 1,
        }
    }

    /// Serialises the value to its stored form.
    pub fn serialize(&self) -> Vec<u8> {
        let mut out = Vec::new();
        self.write_to(&mut out);
        out
    }

    /// Appends the stored form of the value to `out`.
    pub fn write_to(&self, out: &mut Vec<u8>) {
        match self {
            Value::Null => out.push(0),
            Value::Bool(false) => out.push(1),
            Value::Bool(true) => out.push(2),
            Value::Int(v) => {
                out.push(3);
                out.extend_from_slice(&v.to_be_bytes());
            }
            Value::Str(s) => {
                out.push(4);
                out.extend_from_slice(&(s.len() as u32).to_be_bytes());
                out.extend_from_slice(s.as_bytes());
            }
            Value::List(items) => {
                out.push(5);
                out.extend_from_slice(&(items.len() as u32).to_be_bytes());
                for item in items {
                    item.write_to(out);
                }
            }
            Value::Object(fields) => {
                out.push(6);
                out.extend_from_slice(&(fields.len() as u32).to_be_bytes());
                for (name, value) in fields {
                    out.extend_from_slice(&(name.len() as u32).to_be_bytes());
                    out.extend_from_slice(name.as_bytes());
                    value.write_to(out);
                }
            }
        }
    }

    /// Decodes a stored document. Returns [`Error::Corrupt`] for malformed
    /// input or trailing bytes.
    pub fn deserialize(bytes: &[u8]) -> Result<Value> {
        let mut r = Reader { bytes, pos: 0 };
        let v = r.value(0)?;
        if r.pos != bytes.len() {
            return Err(Error::Corrupt);
        }
        Ok(v)
    }

    /// Renders the value as a single line without whitespace (spec §4.4).
    pub fn render(&self) -> String {
        let mut s = String::new();
        self.render_into(&mut s);
        s
    }

    /// Appends the canonical rendering to `out`.
    pub fn render_into(&self, out: &mut String) {
        match self {
            Value::Null => out.push_str("null"),
            Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Value::Int(v) => out.push_str(&v.to_string()),
            Value::Str(s) => render_string(s, out),
            Value::List(items) => {
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    item.render_into(out);
                }
                out.push(']');
            }
            Value::Object(fields) => {
                out.push('{');
                for (i, (name, value)) in fields.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    render_string(name, out);
                    out.push(':');
                    value.render_into(out);
                }
                out.push('}');
            }
        }
    }

    /// Resolves a field path: each segment must name a field of the current
    /// object. Lists are never traversed. `None` means *missing*.
    pub fn get_path<S: AsRef<str>>(&self, segments: &[S]) -> Option<&Value> {
        let mut cur = self;
        for seg in segments {
            match cur {
                Value::Object(fields) => cur = fields.get(seg.as_ref())?,
                _ => return None,
            }
        }
        Some(cur)
    }

    /// Sets the field at `segments`, creating empty objects for missing
    /// intermediate segments. Fails with [`Error::NotObject`] if any value on
    /// the way (including `self`) is present and not an object.
    pub fn set_path<S: AsRef<str>>(&mut self, segments: &[S], value: Value) -> Result<()> {
        let mut cur = self;
        let n = segments.len();
        for (i, seg) in segments.iter().enumerate() {
            let fields = match cur {
                Value::Object(f) => f,
                _ => return Err(Error::NotObject),
            };
            if i + 1 == n {
                fields.insert(seg.as_ref().to_string(), value);
                return Ok(());
            }
            cur = fields
                .entry(seg.as_ref().to_string())
                .or_insert_with(|| Value::Object(BTreeMap::new()));
        }
        Ok(())
    }

    /// Removes the field at `segments`. [`Error::NotObject`] if a value on the
    /// way is not an object, [`Error::NoField`] if a field is missing; the
    /// first failure along the path decides.
    pub fn unset_path<S: AsRef<str>>(&mut self, segments: &[S]) -> Result<()> {
        let mut cur = self;
        let n = segments.len();
        for (i, seg) in segments.iter().enumerate() {
            let fields = match cur {
                Value::Object(f) => f,
                _ => return Err(Error::NotObject),
            };
            if i + 1 == n {
                return fields.remove(seg.as_ref()).map(|_| ()).ok_or(Error::NoField);
            }
            cur = fields.get_mut(seg.as_ref()).ok_or(Error::NoField)?;
        }
        Ok(())
    }
}

/// Appends `s` to `out` as a quoted, escaped string (spec §4.5).
pub fn render_string(s: &str, out: &mut String) {
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
            c if (c as u32) < 0x20 || c as u32 == 0x7f => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl Reader<'_> {
    fn take(&mut self, n: usize) -> Result<&[u8]> {
        let end = self.pos.checked_add(n).ok_or(Error::Corrupt)?;
        let s = self.bytes.get(self.pos..end).ok_or(Error::Corrupt)?;
        self.pos = end;
        Ok(s)
    }

    fn u32(&mut self) -> Result<usize> {
        let b = self.take(4)?;
        Ok(u32::from_be_bytes([b[0], b[1], b[2], b[3]]) as usize)
    }

    fn string(&mut self) -> Result<String> {
        let n = self.u32()?;
        let b = self.take(n)?;
        String::from_utf8(b.to_vec()).map_err(|_| Error::Corrupt)
    }

    fn value(&mut self, depth: usize) -> Result<Value> {
        if depth > 64 {
            return Err(Error::Corrupt);
        }
        let tag = self.take(1)?[0];
        Ok(match tag {
            0 => Value::Null,
            1 => Value::Bool(false),
            2 => Value::Bool(true),
            3 => {
                let b = self.take(8)?;
                Value::Int(i64::from_be_bytes(b.try_into().map_err(|_| Error::Corrupt)?))
            }
            4 => Value::Str(self.string()?),
            5 => {
                let n = self.u32()?;
                let mut items = Vec::with_capacity(n.min(1024));
                for _ in 0..n {
                    items.push(self.value(depth + 1)?);
                }
                Value::List(items)
            }
            6 => {
                let n = self.u32()?;
                let mut fields = BTreeMap::new();
                for _ in 0..n {
                    let name = self.string()?;
                    let v = self.value(depth + 1)?;
                    fields.insert(name, v);
                }
                Value::Object(fields)
            }
            _ => return Err(Error::Corrupt),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn obj(fields: &[(&str, Value)]) -> Value {
        Value::Object(fields.iter().map(|(k, v)| (k.to_string(), v.clone())).collect())
    }

    #[test]
    fn serialises_like_the_spec() {
        assert_eq!(Value::Int(1).serialize(), [3, 0, 0, 0, 0, 0, 0, 0, 1]);
        assert_eq!(Value::Int(-1).serialize(), [3, 255, 255, 255, 255, 255, 255, 255, 255]);
        assert_eq!(Value::Null.serialize(), [0]);
        assert_eq!(Value::Str("ada".into()).serialize(), [4, 0, 0, 0, 3, b'a', b'd', b'a']);
        let doc = obj(&[
            ("name", Value::Str("ada".into())),
            ("age", Value::Int(36)),
            ("ok", Value::Bool(true)),
        ]);
        assert_eq!(doc.serialize().len(), 44);
        assert_eq!(Value::deserialize(&doc.serialize()).unwrap(), doc);
    }

    #[test]
    fn renders_canonically() {
        let doc = obj(&[("name", Value::Str("ada".into())), ("age", Value::Int(36))]);
        assert_eq!(doc.render(), r#"{"age":36,"name":"ada"}"#);
        assert_eq!(Value::Str("a\"b\u{1}\u{7f}é/".into()).render(), "\"a\\\"b\\u0001\\u007fé/\"");
        assert_eq!(Value::List(vec![]).render(), "[]");
    }

    #[test]
    fn depth_counts_levels() {
        assert_eq!(Value::Int(1).depth(), 1);
        assert_eq!(Value::List(vec![]).depth(), 1);
        assert_eq!(Value::List(vec![Value::List(vec![])]).depth(), 2);
    }

    #[test]
    fn path_operations() {
        let mut doc = obj(&[("name", Value::Str("ada".into()))]);
        doc.set_path(&["addr", "city"], Value::Str("oslo".into())).unwrap();
        assert_eq!(doc.get_path(&["addr", "city"]), Some(&Value::Str("oslo".into())));
        assert_eq!(doc.set_path(&["name", "x"], Value::Null), Err(Error::NotObject));
        assert_eq!(doc.unset_path(&["addr", "zip"]), Err(Error::NoField));
        assert_eq!(doc.unset_path(&["name", "first"]), Err(Error::NotObject));
        doc.unset_path(&["addr", "city"]).unwrap();
        assert_eq!(doc.get_path(&["addr"]), Some(&obj(&[])));
        assert_eq!(Value::List(vec![]).get_path(&["a"]), None);
    }

    #[test]
    fn rejects_garbage() {
        assert!(Value::deserialize(&[9]).is_err());
        assert!(Value::deserialize(&[4, 0, 0, 0, 5, b'a']).is_err());
        assert!(Value::deserialize(&[0, 0]).is_err());
    }
}
