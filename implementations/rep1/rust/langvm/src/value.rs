//! Run-time values.

use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};
use std::rc::Rc;

/// A fast, deterministic hasher (FxHash-style) for map keys.
#[derive(Default, Clone, Copy)]
pub struct FxHasher {
    hash: u64,
}

const SEED: u64 = 0x51_7c_c1_b7_27_22_0a_95;

impl Hasher for FxHasher {
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.hash = (self.hash.rotate_left(5) ^ b as u64).wrapping_mul(SEED);
        }
    }
    fn write_u8(&mut self, i: u8) {
        self.hash = (self.hash.rotate_left(5) ^ i as u64).wrapping_mul(SEED);
    }
    fn write_u32(&mut self, i: u32) {
        self.hash = (self.hash.rotate_left(5) ^ i as u64).wrapping_mul(SEED);
    }
    fn write_u64(&mut self, i: u64) {
        self.hash = (self.hash.rotate_left(5) ^ i).wrapping_mul(SEED);
    }
    fn write_usize(&mut self, i: usize) {
        self.write_u64(i as u64);
    }
    fn finish(&self) -> u64 {
        self.hash
    }
}

type Fx = BuildHasherDefault<FxHasher>;

/// A run-time value.
#[derive(Clone, Debug)]
pub enum Value {
    /// The unit value.
    Unit,
    /// A boolean.
    Bool(bool),
    /// A 64-bit integer.
    Int(i64),
    /// A double.
    Float(f64),
    /// A Unicode scalar value.
    Char(char),
    /// A string (sequence of scalar values).
    Str(Rc<Vec<char>>),
    /// A mutable list.
    List(Rc<RefCell<Vec<Value>>>),
    /// A mutable insertion-ordered map.
    Map(Rc<RefCell<MapObj>>),
    /// An immutable tuple.
    Tuple(Rc<Vec<Value>>),
    /// A struct instance.
    Struct(Rc<StructVal>),
    /// An enum value.
    Enum(Rc<EnumVal>),
    /// A closure.
    Closure(Rc<Closure>),
}

/// A struct instance.
#[derive(Debug)]
pub struct StructVal {
    /// Declaration id.
    pub decl: u32,
    /// Field values in declaration order.
    pub fields: Vec<Value>,
}

/// An enum value.
#[derive(Debug)]
pub struct EnumVal {
    /// Declaration id.
    pub decl: u32,
    /// Variant index.
    pub variant: u16,
    /// Payload.
    pub fields: Vec<Value>,
}

/// A closure: a function and its captured values.
#[derive(Debug)]
pub struct Closure {
    /// Function index.
    pub func: u32,
    /// Captured upvalues.
    pub upvals: Vec<Value>,
}

/// A hashable map key.
#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub enum Key {
    /// Integer key.
    Int(i64),
    /// Boolean key.
    Bool(bool),
    /// Character key.
    Char(char),
    /// String key.
    Str(Rc<Vec<char>>),
}

impl Key {
    /// Converts a value of a `Key` type.
    pub fn of(v: &Value) -> Key {
        match v {
            Value::Int(i) => Key::Int(*i),
            Value::Bool(b) => Key::Bool(*b),
            Value::Char(c) => Key::Char(*c),
            Value::Str(s) => Key::Str(s.clone()),
            _ => unreachable!("map key of non-key type"),
        }
    }
}

/// An insertion-ordered hash map.
#[derive(Debug, Default)]
pub struct MapObj {
    entries: Vec<Option<(Value, Value)>>,
    index: HashMap<Key, usize, Fx>,
}

impl MapObj {
    /// Creates an empty map.
    pub fn new() -> MapObj {
        MapObj::default()
    }
    /// Number of live entries.
    pub fn len(&self) -> usize {
        self.index.len()
    }
    /// Whether the map is empty.
    pub fn is_empty(&self) -> bool {
        self.index.is_empty()
    }
    /// Looks up a key.
    pub fn get(&self, k: &Value) -> Option<&Value> {
        let i = *self.index.get(&Key::of(k))?;
        self.entries[i].as_ref().map(|e| &e.1)
    }
    /// Whether the key is present.
    pub fn contains(&self, k: &Value) -> bool {
        self.index.contains_key(&Key::of(k))
    }
    /// Inserts or updates; a present key keeps its position.
    pub fn insert(&mut self, k: Value, v: Value) {
        let key = Key::of(&k);
        if let Some(&i) = self.index.get(&key) {
            if let Some(e) = self.entries[i].as_mut() {
                e.1 = v;
            }
        } else {
            self.index.insert(key, self.entries.len());
            self.entries.push(Some((k, v)));
        }
    }
    /// Removes a key; returns whether it was present.
    pub fn remove(&mut self, k: &Value) -> bool {
        match self.index.remove(&Key::of(k)) {
            None => false,
            Some(i) => {
                self.entries[i] = None;
                if self.entries.len() > 32 && self.index.len() * 2 < self.entries.len() {
                    self.compact();
                }
                true
            }
        }
    }
    fn compact(&mut self) {
        let old = std::mem::take(&mut self.entries);
        self.index.clear();
        for e in old.into_iter().flatten() {
            self.index.insert(Key::of(&e.0), self.entries.len());
            self.entries.push(Some(e));
        }
    }
    /// Removes everything.
    pub fn clear(&mut self) {
        self.entries.clear();
        self.index.clear();
    }
    /// Iterates entries in insertion order.
    pub fn iter(&self) -> impl Iterator<Item = &(Value, Value)> {
        self.entries.iter().flatten()
    }
}

impl Value {
    /// Builds a string value from a Rust string.
    pub fn str_of(s: &str) -> Value {
        Value::Str(Rc::new(s.chars().collect()))
    }
    /// Builds a new list value.
    pub fn list_of(v: Vec<Value>) -> Value {
        Value::List(Rc::new(RefCell::new(v)))
    }
}

/// Structural equality (section 10.4).
pub fn value_eq(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Int(x), Value::Int(y)) => x == y,
        (Value::Float(x), Value::Float(y)) => x == y,
        (Value::Bool(x), Value::Bool(y)) => x == y,
        (Value::Char(x), Value::Char(y)) => x == y,
        (Value::Str(x), Value::Str(y)) => Rc::ptr_eq(x, y) || x == y,
        (Value::Unit, Value::Unit) => true,
        (Value::Tuple(x), Value::Tuple(y)) => {
            x.len() == y.len() && x.iter().zip(y.iter()).all(|(p, q)| value_eq(p, q))
        }
        (Value::Struct(x), Value::Struct(y)) => {
            x.fields.iter().zip(y.fields.iter()).all(|(p, q)| value_eq(p, q))
        }
        (Value::Enum(x), Value::Enum(y)) => {
            x.variant == y.variant
                && x.fields.len() == y.fields.len()
                && x.fields.iter().zip(y.fields.iter()).all(|(p, q)| value_eq(p, q))
        }
        (Value::List(x), Value::List(y)) => {
            if Rc::ptr_eq(x, y) {
                // identical objects are element-wise equal unless they hold NaN;
                // fall through to the element comparison to stay faithful.
            }
            let x = x.borrow();
            let y = y.borrow();
            x.len() == y.len() && x.iter().zip(y.iter()).all(|(p, q)| value_eq(p, q))
        }
        (Value::Map(x), Value::Map(y)) => {
            let x = x.borrow();
            let y = y.borrow();
            if x.len() != y.len() {
                return false;
            }
            let r = x.iter().all(|(k, v)| match y.get(k) {
                Some(w) => value_eq(v, w),
                None => false,
            });
            r
        }
        _ => false,
    }
}

/// Ordering on `Int`, `Float`, `Bool`, `Char` and `Str` values; `None` when
/// a NaN is involved.
pub fn value_cmp(a: &Value, b: &Value) -> Option<Ordering> {
    match (a, b) {
        (Value::Int(x), Value::Int(y)) => Some(x.cmp(y)),
        (Value::Float(x), Value::Float(y)) => x.partial_cmp(y),
        (Value::Bool(x), Value::Bool(y)) => Some(x.cmp(y)),
        (Value::Char(x), Value::Char(y)) => Some(x.cmp(y)),
        (Value::Str(x), Value::Str(y)) => Some(x.as_slice().cmp(y.as_slice())),
        _ => None,
    }
}
