//! Identifier interning.

use std::collections::HashMap;

/// An interned identifier. Cheap to copy and compare; usable as an index.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Sym(pub(crate) u32);

/// Maps identifier text to [`Sym`]s and back.
#[derive(Default, Debug)]
pub struct Interner {
    map: HashMap<String, Sym>,
    names: Vec<String>,
}

impl Interner {
    /// Creates an empty interner.
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns the symbol for `name`, creating it if necessary.
    pub fn intern(&mut self, name: &str) -> Sym {
        if let Some(&s) = self.map.get(name) {
            return s;
        }
        let s = Sym(self.names.len() as u32);
        self.names.push(name.to_owned());
        self.map.insert(name.to_owned(), s);
        s
    }

    /// The text of an interned symbol.
    pub fn name(&self, s: Sym) -> &str {
        &self.names[s.0 as usize]
    }
}
