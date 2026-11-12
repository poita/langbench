//! # cardgame — a rules engine for Spiremark
//!
//! Spiremark is an invented two-player duelling-card game. This crate
//! implements its complete, deterministic rules: it reads a *match file* (a
//! setup block followed by a script of player actions and inspection
//! directives), simulates the match, and produces a log with one line per
//! rules event.
//!
//! The pieces, from the outside in:
//!
//! * [`run_match`] — the whole pipeline: text in, text out. This is what the
//!   command-line tool calls.
//! * [`matchfile`] — parsing of the setup block and script lines.
//! * [`database`], [`sexpr`], [`model`] — the card database: an s-expression
//!   reader, a validator, and the typed card/effect model it produces.
//! * [`Engine`] — the resumable game engine. Build one with
//!   [`Engine::new`], feed it commands with [`Engine::execute`], and read the
//!   log with [`Engine::take_output`].
//! * [`rng`] — the xorshift\* generator that drives shuffles and
//!   `random-unit`.
//!
//! Internally the engine is split by responsibility: `derive` (continuous
//! effects and layers), `eval` (selectors, filters, amounts), `effects` (the
//! effect interpreter), `procedures` (damage, destruction, drawing, …),
//! `triggers`, `targets`, `chain` (playing and resolving), `turn` (phases,
//! priority, state checks), `combat`, `legal`, and `dump`.
//!
//! # Example
//!
//! ```
//! let card_db = "(card AAA-001 (name \"Imp\") (type unit) (cost 1) (body 2 1))";
//! let path = std::env::temp_dir().join("cardgame_doc_example.spire");
//! std::fs::write(&path, card_db).unwrap();
//!
//! let input = format!(
//!     "CARDS {}\nSEED 1\nOPENING 0\nSHUFFLE off\nHAND A AAA-001\nSTART\nA PASS\nB PASS\n",
//!     path.display()
//! );
//! let log = cardgame::run_match(&input);
//! assert!(log.starts_with("1 GAME-START A\n"));
//! assert!(log.ends_with("RESULT pending none\n"));
//! ```

pub mod database;
pub mod matchfile;
pub mod model;
pub mod rng;
pub mod sexpr;

mod chain;
mod combat;
mod derive;
mod dump;
mod effects;
mod engine;
mod eval;
mod legal;
mod procedures;
mod state;
mod targets;
mod triggers;
mod turn;

use std::rc::Rc;

pub use database::{Database, DatabaseError};
pub use engine::EngineError;
pub use matchfile::{Action, Command, Setup, SetupError, TargetToken, Trace};
pub use state::{Engine, MatchResult};

/// Run a whole match file and return the complete output.
///
/// Fatal problems produce a single `FATAL …` line (SPEC.md section 8);
/// everything else, including rejected actions, is reported inside the log.
/// The card database named by the `CARDS` line is read from the file system;
/// a relative path is resolved against the current working directory.
pub fn run_match(input: &str) -> String {
    let lines = matchfile::split_lines(input);
    let (setup, start) = match matchfile::parse_setup(&lines) {
        Ok(v) => v,
        Err(_) => return "FATAL bad-setup\n".to_string(),
    };
    let db = match Database::load(&setup.cards_path) {
        Ok(db) => db,
        Err(_) => return "FATAL bad-database\n".to_string(),
    };
    let mut engine = match Engine::new(&setup, Rc::new(db)) {
        Ok(e) => e,
        Err(EngineError::UnknownCard(_)) => return "FATAL unknown-card\n".to_string(),
    };
    for (i, line) in lines[start..].iter().enumerate() {
        if matchfile::is_comment_line(line) {
            continue;
        }
        let line_no = start + i + 1;
        match matchfile::parse_command(line) {
            Some(cmd) => engine.execute(line_no, cmd),
            None => engine.syntax_error(line_no),
        }
    }
    engine.finish();
    engine.take_output()
}
