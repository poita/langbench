//! The [`Repository`]: object store, refs and parsed-object caches.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::Path;
use std::rc::Rc;

use crate::error::{Error, Result};
use crate::object::{parse_tree, Commit, Kind, Object, TreeEntry};
use crate::oid::ObjectId;
use crate::refs::Refs;
use crate::store::ObjectStore;

/// A git repository (a `.git` directory or a bare repository) opened for
/// reading.
///
/// Everything read is cached: an object is decoded at most once, and parsed
/// commits and trees are kept as well. The caches use interior mutability,
/// so a `Repository` is not `Sync`.
pub struct Repository {
    store: ObjectStore,
    refs: Refs,
    commits: RefCell<HashMap<ObjectId, Rc<Commit>>>,
    trees: RefCell<HashMap<ObjectId, Rc<Vec<TreeEntry>>>>,
}

impl Repository {
    /// Opens the repository whose `HEAD`, `refs/` and `objects/` live
    /// directly inside `path`.
    ///
    /// Fails only if `path` is not a directory.
    pub fn open(path: &Path) -> Result<Repository> {
        if !path.is_dir() {
            return Err(Error::Io(format!("{} is not a directory", path.display())));
        }
        Ok(Repository {
            store: ObjectStore::open(&path.join("objects")),
            refs: Refs::open(path),
            commits: RefCell::new(HashMap::new()),
            trees: RefCell::new(HashMap::new()),
        })
    }

    /// The underlying object store.
    pub fn store(&self) -> &ObjectStore {
        &self.store
    }

    /// The repository's refs.
    pub fn refs(&self) -> &Refs {
        &self.refs
    }

    /// Reads an object (not verified against its id).
    pub fn read_object(&self, id: &ObjectId) -> Result<Rc<Object>> {
        self.store.read(id)
    }

    /// Reads an object and checks that the SHA-1 of its stored form is `id`.
    pub fn read_verified(&self, id: &ObjectId) -> Result<Rc<Object>> {
        let object = self.store.read(id)?;
        if object.compute_id() != *id {
            return Err(Error::corrupt(format!("object {id} fails its hash check")));
        }
        Ok(object)
    }

    /// Reads and parses a commit; fails if the object is not a commit.
    pub fn commit(&self, id: &ObjectId) -> Result<Rc<Commit>> {
        if let Some(c) = self.commits.borrow().get(id) {
            return Ok(Rc::clone(c));
        }
        let object = self.store.read(id)?;
        if object.kind != Kind::Commit {
            return Err(Error::invalid(format!("{id} is not a commit")));
        }
        let commit = Rc::new(Commit::parse(&object.data)?);
        self.commits.borrow_mut().insert(*id, Rc::clone(&commit));
        Ok(commit)
    }

    /// Reads and parses a tree; fails if the object is not a tree.
    pub fn tree(&self, id: &ObjectId) -> Result<Rc<Vec<TreeEntry>>> {
        if let Some(t) = self.trees.borrow().get(id) {
            return Ok(Rc::clone(t));
        }
        let object = self.store.read(id)?;
        if object.kind != Kind::Tree {
            return Err(Error::invalid(format!("{id} is not a tree")));
        }
        let tree = Rc::new(parse_tree(&object.data)?);
        self.trees.borrow_mut().insert(*id, Rc::clone(&tree));
        Ok(tree)
    }
}
