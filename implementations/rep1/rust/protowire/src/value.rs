//! The in-memory value tree: one [`Message`] node per message instance.

use std::cell::Cell;

/// A single field value.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    /// Any integer or bool scalar, normalised to 64 bits: signed types are
    /// stored sign-extended, unsigned types zero-extended, bool as 0 or 1.
    /// The field's [`ScalarType`](crate::ScalarType) says how to interpret it.
    Num(u64),
    /// A `string` value (always valid UTF-8).
    Str(String),
    /// A `bytes` value.
    Bytes(Vec<u8>),
    /// A sub-message.
    Msg(Message),
}

/// The contents of a present field.
#[derive(Debug, Clone, PartialEq)]
pub enum FieldValue {
    /// A singular field's value.
    Single(Value),
    /// A repeated field's elements, in order.
    List(Vec<Value>),
}

/// A message instance: one optional [`FieldValue`] per field of its
/// [`MessageDesc`](crate::MessageDesc), indexed by slot (the field's
/// position in field-number order).
#[derive(Debug, Clone)]
pub struct Message {
    pub(crate) slots: Vec<Option<FieldValue>>,
    /// Scratch space for the encoder: the encoded size of this message,
    /// filled in by its measuring pass.
    pub(crate) encoded_len: Cell<usize>,
}

impl PartialEq for Message {
    fn eq(&self, other: &Self) -> bool {
        self.slots == other.slots
    }
}

impl Message {
    /// Creates an empty message with room for `field_count` fields.
    pub fn new(field_count: usize) -> Message {
        Message { slots: vec![None; field_count], encoded_len: Cell::new(0) }
    }

    /// The value of the field in `slot`, if present.
    pub fn get(&self, slot: usize) -> Option<&FieldValue> {
        self.slots.get(slot).and_then(Option::as_ref)
    }

    /// Sets the value of the field in `slot`.
    ///
    /// # Panics
    /// Panics if `slot` is out of range.
    pub fn set(&mut self, slot: usize, value: FieldValue) {
        self.slots[slot] = Some(value);
    }
}
