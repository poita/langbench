//! Lexical scopes and per-rendering inheritance state.

use crate::ast::Node;
use crate::value::{Dict, Value};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

/// A mapping from names to values plus a parent scope. Creating a scope is
/// O(1); a lookup walks the chain of parents.
pub struct Scope {
    vars: RefCell<Dict>,
    parent: Option<Rc<Scope>>,
}

impl Scope {
    /// A scope with no parent holding the given variables.
    pub fn root(vars: Dict) -> Rc<Scope> {
        Rc::new(Scope { vars: RefCell::new(vars), parent: None })
    }

    /// A new empty scope whose parent is `parent`.
    pub fn child(parent: &Rc<Scope>) -> Rc<Scope> {
        Rc::new(Scope { vars: RefCell::new(Dict::new()), parent: Some(parent.clone()) })
    }

    /// Binds `name` in this scope only.
    pub fn set(&self, name: Rc<str>, value: Value) {
        self.vars.borrow_mut().insert(name, value);
    }

    /// Looks `name` up through the chain; unbound names yield
    /// [`Value::Undefined`].
    pub fn lookup(&self, name: &str) -> Value {
        let mut scope = self;
        loop {
            if let Some(v) = scope.vars.borrow().get(name) {
                return v.clone();
            }
            match &scope.parent {
                Some(p) => scope = p,
                None => return Value::Undefined,
            }
        }
    }
}

/// The bodies of one block, most derived first.
pub(crate) type Chain = Vec<Rc<Vec<Node>>>;

/// State of one rendering (the main template, or one `include`): the
/// template scope and, per block name, the chain of bodies.
pub struct Rendering {
    pub(crate) scope: Rc<Scope>,
    pub(crate) chains: RefCell<HashMap<Rc<str>, Chain>>,
}

impl Rendering {
    pub(crate) fn new(scope: Rc<Scope>) -> Rc<Rendering> {
        Rc::new(Rendering { scope, chains: RefCell::new(HashMap::new()) })
    }
}
