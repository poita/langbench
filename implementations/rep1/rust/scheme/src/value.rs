//! Runtime values: [`Value`], interned [`Symbol`]s and pairs.

use std::cell::RefCell;
use std::fmt;
use std::rc::Rc;

use crate::analyze::LambdaDef;
use crate::bigint::BigInt;
use crate::env::Env;
use crate::primitives::Primitive;

/// An interned symbol. Two symbols are equal iff they have the same name.
///
/// Interning uses a thread-local table, so symbols (and therefore [`Value`]s)
/// must stay on the thread that created them.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct Symbol(pub(crate) u32);

/// Names of the reserved words, interned first so that they have fixed ids.
const RESERVED: [&str; 13] = [
    "quote", "if", "define", "set!", "lambda", "let", "let*", "letrec", "begin", "cond", "and",
    "or", "else",
];

pub(crate) const QUOTE: Symbol = Symbol(0);
pub(crate) const IF: Symbol = Symbol(1);
pub(crate) const DEFINE: Symbol = Symbol(2);
pub(crate) const SET: Symbol = Symbol(3);
pub(crate) const LAMBDA: Symbol = Symbol(4);
pub(crate) const LET: Symbol = Symbol(5);
pub(crate) const LET_STAR: Symbol = Symbol(6);
pub(crate) const LETREC: Symbol = Symbol(7);
pub(crate) const BEGIN: Symbol = Symbol(8);
pub(crate) const COND: Symbol = Symbol(9);
pub(crate) const AND: Symbol = Symbol(10);
pub(crate) const OR: Symbol = Symbol(11);
pub(crate) const ELSE: Symbol = Symbol(12);

struct Interner {
    names: Vec<Rc<str>>,
    ids: std::collections::HashMap<Rc<str>, u32>,
}

impl Interner {
    fn new() -> Interner {
        let mut i = Interner { names: Vec::new(), ids: std::collections::HashMap::new() };
        for name in RESERVED {
            i.intern(name);
        }
        i
    }

    fn intern(&mut self, name: &str) -> u32 {
        if let Some(&id) = self.ids.get(name) {
            return id;
        }
        let rc: Rc<str> = Rc::from(name);
        let id = self.names.len() as u32;
        self.names.push(rc.clone());
        self.ids.insert(rc, id);
        id
    }
}

thread_local! {
    static INTERNER: RefCell<Interner> = RefCell::new(Interner::new());
}

impl Symbol {
    /// Interns `name`, returning the unique symbol with that name.
    pub fn new(name: &str) -> Symbol {
        Symbol(INTERNER.with(|i| i.borrow_mut().intern(name)))
    }

    /// The symbol's name.
    pub fn name(self) -> Rc<str> {
        INTERNER.with(|i| i.borrow().names[self.0 as usize].clone())
    }

    pub(crate) fn index(self) -> usize {
        self.0 as usize
    }
}

impl fmt::Display for Symbol {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.name())
    }
}

/// A cons cell. Pairs are immutable.
pub struct Pair {
    /// The first component.
    pub car: Value,
    /// The second component.
    pub cdr: Value,
}

impl Drop for Pair {
    // Dropping a long list recursively would overflow the stack; unlink the
    // spine iteratively instead.
    fn drop(&mut self) {
        let mut next = std::mem::replace(&mut self.cdr, Value::Nil);
        while let Value::Pair(rc) = next {
            match Rc::try_unwrap(rc) {
                Ok(mut p) => next = std::mem::replace(&mut p.cdr, Value::Nil),
                Err(_) => break,
            }
        }
    }
}

/// A user-defined procedure: a lambda together with its defining environment.
pub struct Closure {
    pub(crate) def: Rc<LambdaDef>,
    pub(crate) env: Env,
}

/// A Scheme value.
///
/// Integers that fit in an `i64` are always represented as [`Value::Int`];
/// [`Value::Big`] is used only for integers outside that range. Use
/// [`Value::from_bigint`] to build a correctly normalised integer.
#[derive(Clone)]
pub enum Value {
    /// The void value (result of `define`, `display`, ...).
    Void,
    /// The empty list.
    Nil,
    /// `#t` or `#f`.
    Bool(bool),
    /// An integer that fits in a machine word.
    Int(i64),
    /// An integer outside the `i64` range.
    Big(Rc<BigInt>),
    /// A string.
    Str(Rc<str>),
    /// A symbol.
    Sym(Symbol),
    /// A pair.
    Pair(Rc<Pair>),
    /// A closure.
    Closure(Rc<Closure>),
    /// A built-in procedure.
    Prim(&'static Primitive),
}

impl Value {
    /// Builds a pair.
    pub fn cons(car: Value, cdr: Value) -> Value {
        Value::Pair(Rc::new(Pair { car, cdr }))
    }

    /// Builds a string value.
    pub fn string(s: &str) -> Value {
        Value::Str(Rc::from(s))
    }

    /// Builds a symbol value.
    pub fn symbol(name: &str) -> Value {
        Value::Sym(Symbol::new(name))
    }

    /// Builds a proper list from the items.
    pub fn list<I>(items: I) -> Value
    where
        I: IntoIterator<Item = Value>,
        I::IntoIter: DoubleEndedIterator,
    {
        items.into_iter().rev().fold(Value::Nil, |tail, x| Value::cons(x, tail))
    }

    /// Normalises a [`BigInt`] into an integer value.
    pub fn from_bigint(b: BigInt) -> Value {
        match b.to_i64() {
            Some(i) => Value::Int(i),
            None => Value::Big(Rc::new(b)),
        }
    }

    /// Whether the value counts as true (everything except `#f`).
    pub fn is_truthy(&self) -> bool {
        !matches!(self, Value::Bool(false))
    }

    /// Whether the value is an integer.
    pub fn is_integer(&self) -> bool {
        matches!(self, Value::Int(_) | Value::Big(_))
    }

    /// If the value is a proper list, returns its elements.
    pub fn list_to_vec(&self) -> Option<Vec<Value>> {
        let mut out = Vec::new();
        let mut cur = self;
        loop {
            match cur {
                Value::Nil => return Some(out),
                Value::Pair(p) => {
                    out.push(p.car.clone());
                    cur = &p.cdr;
                }
                _ => return None,
            }
        }
    }

    /// The `eq?` relation: numeric equality for integers, identity otherwise.
    pub fn is_eq(&self, other: &Value) -> bool {
        match (self, other) {
            (Value::Int(a), Value::Int(b)) => a == b,
            (Value::Big(a), Value::Big(b)) => a == b,
            (Value::Bool(a), Value::Bool(b)) => a == b,
            (Value::Nil, Value::Nil) | (Value::Void, Value::Void) => true,
            (Value::Sym(a), Value::Sym(b)) => a == b,
            (Value::Str(a), Value::Str(b)) => Rc::ptr_eq(a, b),
            (Value::Pair(a), Value::Pair(b)) => Rc::ptr_eq(a, b),
            (Value::Closure(a), Value::Closure(b)) => Rc::ptr_eq(a, b),
            (Value::Prim(a), Value::Prim(b)) => std::ptr::eq(*a, *b),
            _ => false,
        }
    }

    /// The `equal?` relation: structural on pairs and strings, `eq?` otherwise.
    pub fn is_equal(&self, other: &Value) -> bool {
        let (mut a, mut b) = (self, other);
        loop {
            match (a, b) {
                (Value::Pair(x), Value::Pair(y)) => {
                    if Rc::ptr_eq(x, y) {
                        return true;
                    }
                    if !x.car.is_equal(&y.car) {
                        return false;
                    }
                    a = &x.cdr;
                    b = &y.cdr;
                }
                (Value::Str(x), Value::Str(y)) => return x == y,
                _ => return a.is_eq(b),
            }
        }
    }
}

impl fmt::Display for Value {
    /// Formats the value in its *write* form.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&crate::printer::write_string(self))
    }
}

impl fmt::Debug for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}
