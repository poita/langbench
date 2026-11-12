//! The typing environment.
//!
//! Each identifier owns a stack of bindings, so lookup is an array index plus
//! a `last()`, independent of how many names are in scope. A trail records the
//! order of pushes so scopes can be unwound.

use crate::symbol::Sym;
use crate::types::Ty;

/// What a name is bound to.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Binding {
    pub ty: Ty,
    /// True for a type scheme (must be instantiated on use); false for a
    /// monomorphic type, which is used as is.
    pub poly: bool,
}

#[derive(Default, Debug)]
pub(crate) struct Env {
    slots: Vec<Vec<Binding>>,
    trail: Vec<Sym>,
}

impl Env {
    pub fn push(&mut self, name: Sym, b: Binding) {
        let ix = name.0 as usize;
        if self.slots.len() <= ix {
            self.slots.resize_with(ix + 1, Vec::new);
        }
        self.slots[ix].push(b);
        self.trail.push(name);
    }

    pub fn pop(&mut self) {
        let name = self.trail.pop().expect("pop on empty environment");
        self.slots[name.0 as usize].pop();
    }

    pub fn get(&self, name: Sym) -> Option<Binding> {
        self.slots.get(name.0 as usize).and_then(|s| s.last()).copied()
    }

    /// Current trail length, to be passed to [`Env::truncate`] later.
    pub fn mark(&self) -> usize {
        self.trail.len()
    }

    /// Unwinds bindings until the trail has length `mark`.
    pub fn truncate(&mut self, mark: usize) {
        while self.trail.len() > mark {
            self.pop();
        }
    }
}
