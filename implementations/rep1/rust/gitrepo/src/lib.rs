//! # gitrepo
//!
//! A dependency-free reader for git repositories. It understands loose
//! objects, version-2 packfiles (with `OFS_DELTA` and `REF_DELTA` chains),
//! refs and `packed-refs`, and git's revision syntax, and ships its own
//! SHA-1 and DEFLATE implementations.
//!
//! ```no_run
//! use std::path::Path;
//! use gitrepo::{rev, Repository};
//!
//! let repo = Repository::open(Path::new("some/repo/.git"))?;
//! let head = rev::resolve(&repo, b"HEAD~2")?;
//! let commit = repo.commit(&head)?;
//! println!("{head}: {}", String::from_utf8_lossy(&commit.subject()));
//!
//! // Or run one of the command-line queries and get its exact output:
//! let out = gitrepo::commands::execute(&repo, b"log HEAD 3")?;
//! # let _ = out;
//! # Ok::<(), gitrepo::Error>(())
//! ```
//!
//! ## Modules
//!
//! * [`sha1`], [`inflate`], [`delta`] — the primitives.
//! * [`pack`], [`store`] — pack indexes, packs and the object database.
//! * [`object`] — commits, trees and tags.
//! * [`refs`], [`rev`] — refs and revision resolution.
//! * [`repo`] — the [`Repository`] that ties them together.
//! * [`commands`], [`quote`] — the query implementations.

pub mod commands;
pub mod delta;
pub mod error;
pub mod inflate;
pub mod object;
pub mod oid;
pub mod pack;
pub mod quote;
pub mod refs;
pub mod repo;
pub mod rev;
pub mod sha1;
pub mod store;

pub use error::{Error, Result};
pub use oid::ObjectId;
pub use repo::Repository;
