//! Running commands against a [`Database`] and producing `results.txt`.

use crate::command::Command;
use crate::db::{Database, FindResult, IndexInfo, PutOutcome, ScanRow, Stat};
use crate::error::Result;
use crate::parser::parse_command;
use crate::render::render_block;
use crate::value::Value;

/// The successful outcome of a command.
#[derive(Clone, Debug, PartialEq)]
pub enum Response {
    /// `begin`
    Begin,
    /// `commit`
    Commit {
        /// New commit counter.
        txn_id: u64,
        /// Page images appended to the log.
        frames: u32,
    },
    /// `rollback`
    Rollback,
    /// `checkpoint`
    Checkpoint {
        /// Pages copied into the main file.
        pages: usize,
    },
    /// `put`
    Put(PutOutcome),
    /// `get`
    Get(Value),
    /// `delete`
    Delete,
    /// `update`
    Update,
    /// `unset`
    Unset,
    /// `scan`
    Scan(Vec<ScanRow>),
    /// `find`
    Find(FindResult),
    /// `create index`
    CreateIndex {
        /// Path text.
        path: String,
        /// Entries in the new index.
        entries: u32,
    },
    /// `drop index`
    DropIndex {
        /// Path text.
        path: String,
        /// Pages freed.
        pages: usize,
    },
    /// `indexes`
    Indexes(Vec<IndexInfo>),
    /// `stat`
    Stat(Stat),
}

impl Database {
    /// Executes a parsed command.
    pub fn execute(&mut self, cmd: &Command) -> Result<Response> {
        Ok(match cmd {
            Command::Begin => {
                self.begin()?;
                Response::Begin
            }
            Command::Commit => {
                let info = self.commit()?;
                Response::Commit { txn_id: info.txn_id, frames: info.frames }
            }
            Command::Rollback => {
                self.rollback()?;
                Response::Rollback
            }
            Command::Checkpoint => Response::Checkpoint { pages: self.checkpoint()? },
            Command::Stat => Response::Stat(self.stat()?),
            Command::Indexes => Response::Indexes(self.indexes()),
            Command::Put { key, value } => Response::Put(self.put(key, value)?),
            Command::Get { key } => Response::Get(self.get(key)?),
            Command::Delete { key } => {
                self.delete(key)?;
                Response::Delete
            }
            Command::Update { key, path, value } => {
                self.update(key, path, value.clone())?;
                Response::Update
            }
            Command::Unset { key, path } => {
                self.unset(key, path)?;
                Response::Unset
            }
            Command::Scan(opts) => Response::Scan(self.scan(opts)?),
            Command::Find { pred, limit } => Response::Find(self.find(pred, *limit)?),
            Command::CreateIndex(path) => {
                Response::CreateIndex { path: path.text().to_string(), entries: self.create_index(path)? }
            }
            Command::DropIndex(path) => {
                Response::DropIndex { path: path.text().to_string(), pages: self.drop_index(path)? }
            }
        })
    }

    /// Parses and executes one command line.
    pub fn execute_line(&mut self, line: &str) -> Result<Response> {
        let cmd = parse_command(line)?;
        self.execute(&cmd)
    }

    /// Runs a whole command script and returns the text of `results.txt`.
    ///
    /// Lines are separated by LF; a trailing LF terminates the last line and
    /// does not start another. A transaction still open at the end is rolled
    /// back; no checkpoint is forced.
    pub fn run_script(&mut self, script: &str) -> String {
        let mut out = String::new();
        let mut lines: Vec<&str> = script.split('\n').collect();
        if lines.last() == Some(&"") {
            lines.pop();
        }
        for (i, line) in lines.iter().enumerate() {
            let result = self.execute_line(line);
            out.push_str(&render_block(i + 1, &result));
        }
        if self.in_transaction() {
            let _ = self.rollback();
        }
        out
    }
}
