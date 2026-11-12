//! Environments: a chain of small frames ending in the global table.

use std::cell::RefCell;
use std::rc::Rc;

use crate::value::{Symbol, Value};

/// A local environment frame: a small association list plus a parent link.
pub struct Frame {
    vars: RefCell<Vec<(Symbol, Value)>>,
    parent: Env,
}

/// An environment: `None` is the global environment.
pub type Env = Option<Rc<Frame>>;

impl Frame {
    pub(crate) fn new(vars: Vec<(Symbol, Value)>, parent: Env) -> Rc<Frame> {
        Rc::new(Frame { vars: RefCell::new(vars), parent })
    }

    /// Binds `sym` in this frame, replacing an existing binding of the same
    /// name in this frame.
    pub(crate) fn define(&self, sym: Symbol, value: Value) {
        let mut vars = self.vars.borrow_mut();
        match vars.iter_mut().find(|(k, _)| *k == sym) {
            Some(slot) => slot.1 = value,
            None => vars.push((sym, value)),
        }
    }
}

/// The global environment, a table indexed by symbol id.
#[derive(Default)]
pub(crate) struct Globals {
    slots: Vec<Option<Value>>,
}

impl Globals {
    pub(crate) fn define(&mut self, sym: Symbol, value: Value) {
        let i = sym.index();
        if i >= self.slots.len() {
            self.slots.resize(i + 1, None);
        }
        self.slots[i] = Some(value);
    }

    fn get(&self, sym: Symbol) -> Option<&Value> {
        self.slots.get(sym.index()).and_then(Option::as_ref)
    }

    fn set(&mut self, sym: Symbol, value: Value) -> bool {
        match self.slots.get_mut(sym.index()) {
            Some(slot @ Some(_)) => {
                *slot = Some(value);
                true
            }
            _ => false,
        }
    }
}

/// Looks `sym` up by name: innermost frame first, then the globals.
pub(crate) fn lookup(globals: &Globals, env: &Env, sym: Symbol) -> Option<Value> {
    let mut cur = env;
    while let Some(frame) = cur {
        if let Some((_, v)) = frame.vars.borrow().iter().find(|(k, _)| *k == sym) {
            return Some(v.clone());
        }
        cur = &frame.parent;
    }
    globals.get(sym).cloned()
}

/// Assigns to the nearest enclosing binding of `sym`; false if there is none.
pub(crate) fn assign(globals: &mut Globals, env: &Env, sym: Symbol, value: Value) -> bool {
    let mut cur = env;
    while let Some(frame) = cur {
        if let Some(slot) = frame.vars.borrow_mut().iter_mut().find(|(k, _)| *k == sym) {
            slot.1 = value;
            return true;
        }
        cur = &frame.parent;
    }
    globals.set(sym, value)
}

/// Binds `sym` in the innermost frame of `env` (the globals if `None`).
pub(crate) fn define(globals: &mut Globals, env: &Env, sym: Symbol, value: Value) {
    match env {
        Some(frame) => frame.define(sym, value),
        None => globals.define(sym, value),
    }
}
