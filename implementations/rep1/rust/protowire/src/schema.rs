//! Message schemas: parsing the schema language and resolving types.

use std::collections::HashMap;

use crate::error::{Error, Result};
use crate::wire::WireType;

/// The scalar field types.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScalarType {
    /// `int32`
    Int32,
    /// `int64`
    Int64,
    /// `uint32`
    Uint32,
    /// `uint64`
    Uint64,
    /// `sint32`
    Sint32,
    /// `sint64`
    Sint64,
    /// `bool`
    Bool,
    /// `fixed32`
    Fixed32,
    /// `fixed64`
    Fixed64,
    /// `sfixed32`
    Sfixed32,
    /// `sfixed64`
    Sfixed64,
    /// `string`
    String,
    /// `bytes`
    Bytes,
}

impl ScalarType {
    /// Looks a scalar type up by its schema keyword.
    pub fn from_keyword(word: &str) -> Option<ScalarType> {
        use ScalarType::*;
        Some(match word {
            "int32" => Int32,
            "int64" => Int64,
            "uint32" => Uint32,
            "uint64" => Uint64,
            "sint32" => Sint32,
            "sint64" => Sint64,
            "bool" => Bool,
            "fixed32" => Fixed32,
            "fixed64" => Fixed64,
            "sfixed32" => Sfixed32,
            "sfixed64" => Sfixed64,
            "string" => String,
            "bytes" => Bytes,
            _ => return None,
        })
    }

    /// The wire type a single value of this type uses.
    pub fn wire_type(self) -> WireType {
        use ScalarType::*;
        match self {
            Int32 | Int64 | Uint32 | Uint64 | Sint32 | Sint64 | Bool => WireType::Varint,
            Fixed32 | Sfixed32 => WireType::Fixed32,
            Fixed64 | Sfixed64 => WireType::Fixed64,
            String | Bytes => WireType::Len,
        }
    }

    /// True for every type except `string` and `bytes`: repeated fields of
    /// these types may be packed.
    pub fn is_numeric(self) -> bool {
        !matches!(self, ScalarType::String | ScalarType::Bytes)
    }

    /// True for integer types whose text form is signed.
    pub fn is_signed(self) -> bool {
        use ScalarType::*;
        matches!(self, Int32 | Int64 | Sint32 | Sint64 | Sfixed32 | Sfixed64)
    }

    /// The inclusive range of values of an integer type, or `None` for
    /// non-integer types.
    pub fn int_range(self) -> Option<(i128, i128)> {
        use ScalarType::*;
        Some(match self {
            Int32 | Sint32 | Sfixed32 => (i32::MIN as i128, i32::MAX as i128),
            Int64 | Sint64 | Sfixed64 => (i64::MIN as i128, i64::MAX as i128),
            Uint32 | Fixed32 => (0, u32::MAX as i128),
            Uint64 | Fixed64 => (0, u64::MAX as i128),
            _ => return None,
        })
    }
}

/// Index of a message within a [`Schema`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct MessageId(pub(crate) usize);

/// The resolved type of a field.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FieldKind {
    /// A scalar.
    Scalar(ScalarType),
    /// A sub-message.
    Message(MessageId),
}

/// One field of a message.
#[derive(Debug, Clone)]
pub struct FieldDesc {
    /// Field name.
    pub name: String,
    /// Field number.
    pub number: u32,
    /// Whether the field is `repeated`.
    pub repeated: bool,
    /// The field's type.
    pub kind: FieldKind,
}

/// A message definition. Fields are stored sorted by field number, and a
/// field's position in [`MessageDesc::fields`] is its *slot* index in values.
#[derive(Debug, Clone)]
pub struct MessageDesc {
    /// Message name.
    pub name: String,
    /// Fields in increasing field-number order.
    pub fields: Vec<FieldDesc>,
    by_name: HashMap<String, usize>,
}

impl MessageDesc {
    /// Finds a field by number in O(log F).
    #[inline]
    pub fn field_by_number(&self, number: u32) -> Option<usize> {
        self.fields.binary_search_by_key(&number, |f| f.number).ok()
    }

    /// Finds a field by name in O(1) expected time.
    #[inline]
    pub fn field_by_name(&self, name: &str) -> Option<usize> {
        self.by_name.get(name).copied()
    }
}

/// A parsed schema: a set of message definitions.
#[derive(Debug, Clone)]
pub struct Schema {
    messages: Vec<MessageDesc>,
    by_name: HashMap<String, MessageId>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Tok<'a> {
    Punct(u8),
    Word(&'a str),
}

fn tokenize(src: &str) -> Vec<Tok<'_>> {
    let bytes = src.as_bytes();
    let mut toks = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i];
        if matches!(c, b'{' | b'}' | b';' | b'=') {
            toks.push(Tok::Punct(c));
            i += 1;
        } else if c.is_ascii_alphanumeric() || c == b'_' {
            let start = i;
            while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
                i += 1;
            }
            toks.push(Tok::Word(&src[start..i]));
        } else {
            // Whitespace (and, leniently, anything else) separates tokens.
            i += 1;
        }
    }
    toks
}

struct RawField<'a> {
    repeated: bool,
    type_name: &'a str,
    name: &'a str,
    number: u32,
}

struct Cursor<'t, 'a> {
    toks: &'t [Tok<'a>],
    pos: usize,
}

impl<'t, 'a> Cursor<'t, 'a> {
    fn next(&mut self) -> Option<Tok<'a>> {
        let t = self.toks.get(self.pos).copied();
        self.pos += 1;
        t
    }

    fn peek(&self) -> Option<Tok<'a>> {
        self.toks.get(self.pos).copied()
    }

    fn punct(&mut self, c: u8) -> Result<()> {
        match self.next() {
            Some(Tok::Punct(p)) if p == c => Ok(()),
            _ => Err(Error::Schema(format!("expected `{}`", c as char))),
        }
    }

    fn word(&mut self, what: &str) -> Result<&'a str> {
        match self.next() {
            Some(Tok::Word(w)) => Ok(w),
            _ => Err(Error::Schema(format!("expected {what}"))),
        }
    }
}

impl Schema {
    /// Parses schema source text.
    ///
    /// ```
    /// let schema = protowire::Schema::parse("message A { int32 x = 1; }").unwrap();
    /// assert!(schema.message_id("A").is_some());
    /// ```
    pub fn parse(src: &str) -> Result<Schema> {
        let toks = tokenize(src);
        let mut cur = Cursor { toks: &toks, pos: 0 };
        let mut raw: Vec<(&str, Vec<RawField>)> = Vec::new();
        while cur.peek().is_some() {
            let kw = cur.word("`message`")?;
            if kw != "message" {
                return Err(Error::Schema(format!("expected `message`, found `{kw}`")));
            }
            let name = cur.word("message name")?;
            cur.punct(b'{')?;
            let mut fields = Vec::new();
            while cur.peek() != Some(Tok::Punct(b'}')) {
                let mut type_name = cur.word("field type")?;
                let repeated = type_name == "repeated";
                if repeated {
                    type_name = cur.word("field type")?;
                }
                let fname = cur.word("field name")?;
                cur.punct(b'=')?;
                let num = cur.word("field number")?;
                let number: u32 = num
                    .parse()
                    .map_err(|_| Error::Schema(format!("bad field number `{num}`")))?;
                cur.punct(b';')?;
                fields.push(RawField { repeated, type_name, name: fname, number });
            }
            cur.punct(b'}')?;
            raw.push((name, fields));
        }

        let mut by_name = HashMap::with_capacity(raw.len());
        for (i, (name, _)) in raw.iter().enumerate() {
            if by_name.insert(name.to_string(), MessageId(i)).is_some() {
                return Err(Error::Schema(format!("duplicate message `{name}`")));
            }
        }

        let mut messages = Vec::with_capacity(raw.len());
        for (name, rfields) in raw {
            let mut fields = Vec::with_capacity(rfields.len());
            for f in rfields {
                let kind = match ScalarType::from_keyword(f.type_name) {
                    Some(s) => FieldKind::Scalar(s),
                    None => FieldKind::Message(*by_name.get(f.type_name).ok_or_else(|| {
                        Error::Schema(format!("unknown type `{}`", f.type_name))
                    })?),
                };
                fields.push(FieldDesc {
                    name: f.name.to_string(),
                    number: f.number,
                    repeated: f.repeated,
                    kind,
                });
            }
            fields.sort_by_key(|f| f.number);
            if fields.windows(2).any(|w| w[0].number == w[1].number) {
                return Err(Error::Schema(format!("duplicate field number in `{name}`")));
            }
            let mut field_names = HashMap::with_capacity(fields.len());
            for (i, f) in fields.iter().enumerate() {
                if field_names.insert(f.name.clone(), i).is_some() {
                    return Err(Error::Schema(format!("duplicate field `{}` in `{name}`", f.name)));
                }
            }
            messages.push(MessageDesc { name: name.to_string(), fields, by_name: field_names });
        }
        Ok(Schema { messages, by_name })
    }

    /// Looks a message up by name.
    pub fn message_id(&self, name: &str) -> Option<MessageId> {
        self.by_name.get(name).copied()
    }

    /// The definition of a message.
    #[inline]
    pub fn message(&self, id: MessageId) -> &MessageDesc {
        &self.messages[id.0]
    }

    /// Number of messages in the schema.
    pub fn len(&self) -> usize {
        self.messages.len()
    }

    /// True if the schema defines no messages.
    pub fn is_empty(&self) -> bool {
        self.messages.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_compact_and_multiline() {
        let a = Schema::parse("message A{int32 x=1;repeated B b=2;}message B{string s=3;}").unwrap();
        let b = Schema::parse("message A {\n int32 x = 1;\n\trepeated B b = 2;\r\n}\nmessage B {\n string s = 3;\n}\n").unwrap();
        for s in [a, b] {
            let id = s.message_id("A").unwrap();
            let m = s.message(id);
            assert_eq!(m.fields.len(), 2);
            assert!(m.fields[1].repeated);
            assert_eq!(m.fields[1].kind, FieldKind::Message(s.message_id("B").unwrap()));
        }
    }

    #[test]
    fn fields_sorted_and_recursive() {
        let s = Schema::parse("message N { N next = 9; int32 v = 2; repeated sint64 w = 5; }").unwrap();
        let m = s.message(s.message_id("N").unwrap());
        let nums: Vec<u32> = m.fields.iter().map(|f| f.number).collect();
        assert_eq!(nums, [2, 5, 9]);
        assert_eq!(m.field_by_number(9), Some(2));
        assert_eq!(m.field_by_name("v"), Some(0));
        assert_eq!(m.field_by_number(3), None);
        assert_eq!(m.fields[2].kind, FieldKind::Message(s.message_id("N").unwrap()));
    }

    #[test]
    fn rejects_malformed() {
        assert!(Schema::parse("message A { int32 x = 1 }").is_err());
        assert!(Schema::parse("message A { Foo x = 1; }").is_err());
        assert!(Schema::parse("message A { int32 x = 1; int32 y = 1; }").is_err());
        assert!(Schema::parse("message A { } message A { }").is_err());
    }
}
