//! Compiles a syntax tree into a flat backtracking program.
//!
//! Counted quantifiers are expanded into copies of their body, so the program
//! contains only a handful of instruction kinds. Every write to the capture
//! table (or to a scratch register) is later logged by the matcher so it can
//! be undone on backtracking.
//!
//! Slot layout used by the program:
//!
//! * `2*(g-1)`, `2*(g-1)+1` – start and end of capture group `g`;
//! * `2*G + (g-1)` – scratch: where group `g` was most recently opened;
//! * `3*G + r` – scratch register `r`: where the current iteration of a
//!   loop started (used to detect empty iterations).

use crate::analysis::analyze;
use crate::ast::Node;
use crate::charset::CharSet;
use crate::error::{Error, ErrorKind};

/// Upper bound on program length, to keep nested counted quantifiers from
/// exhausting memory.
const MAX_PROGRAM_LEN: usize = 2_000_000;

/// One instruction of the backtracking machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Inst {
    /// Consume one byte equal to the operand.
    Char(u8),
    /// Consume any byte.
    Any,
    /// Consume one byte contained in `sets[index]`.
    Set(u32),
    /// Succeed only at position 0.
    Bol,
    /// Succeed only at the end of the subject.
    Eol,
    /// Try the first target; on failure resume at the second.
    Split(u32, u32),
    /// Unconditional jump.
    Jmp(u32),
    /// Store the current position in a slot.
    Mark(u32),
    /// Finish capture group `g` (0-based): `caps[g] = (scratch[g], pos)`.
    Close(u32),
    /// If the current position equals the position stored in `slot`
    /// (an empty iteration), jump to the target.
    EmptyExit(u32, u32),
    /// The whole pattern matched.
    Match,
}

/// A compiled pattern.
#[derive(Debug)]
pub struct Program {
    pub insts: Vec<Inst>,
    pub sets: Vec<CharSet>,
    pub group_count: usize,
    /// Total number of slots the matcher needs.
    pub slot_count: usize,
}

/// Compiles `root` (a pattern with `group_count` groups) into a [`Program`].
pub fn compile(root: &Node, group_count: usize) -> Result<Program, Error> {
    let mut c = Compiler {
        insts: Vec::new(),
        sets: Vec::new(),
        group_count,
        max_regs: 0,
    };
    c.node(root, 0)?;
    c.emit(Inst::Match)?;
    Ok(Program {
        insts: c.insts,
        sets: c.sets,
        group_count,
        slot_count: 3 * group_count + c.max_regs,
    })
}

struct Compiler {
    insts: Vec<Inst>,
    sets: Vec<CharSet>,
    group_count: usize,
    max_regs: usize,
}

impl Compiler {
    fn pc(&self) -> u32 {
        self.insts.len() as u32
    }

    fn emit(&mut self, inst: Inst) -> Result<u32, Error> {
        if self.insts.len() >= MAX_PROGRAM_LEN {
            return Err(Error::new(ErrorKind::PatternTooLarge, 0));
        }
        let at = self.pc();
        self.insts.push(inst);
        Ok(at)
    }

    /// Slot used for loop-iteration start at nesting level `depth`.
    fn reg_slot(&mut self, depth: usize) -> u32 {
        self.max_regs = self.max_regs.max(depth + 1);
        (3 * self.group_count + depth) as u32
    }

    /// `depth` is the number of enclosing loops that use a scratch register.
    fn node(&mut self, n: &Node, depth: usize) -> Result<(), Error> {
        match n {
            Node::Empty => {}
            Node::Char(c) => {
                self.emit(Inst::Char(*c))?;
            }
            Node::Any => {
                self.emit(Inst::Any)?;
            }
            Node::Set(s) => {
                let idx = self.sets.len() as u32;
                self.sets.push(*s);
                self.emit(Inst::Set(idx))?;
            }
            Node::Bol => {
                self.emit(Inst::Bol)?;
            }
            Node::Eol => {
                self.emit(Inst::Eol)?;
            }
            Node::Concat(items) => {
                for item in items {
                    self.node(item, depth)?;
                }
            }
            Node::Alt(branches) => {
                let mut jumps = Vec::new();
                let last = branches.len() - 1;
                for (i, b) in branches.iter().enumerate() {
                    if i < last {
                        let split = self.emit(Inst::Split(0, 0))?;
                        self.node(b, depth)?;
                        jumps.push(self.emit(Inst::Jmp(0))?);
                        let next = self.pc();
                        self.insts[split as usize] = Inst::Split(split + 1, next);
                    } else {
                        self.node(b, depth)?;
                    }
                }
                let end = self.pc();
                for j in jumps {
                    self.insts[j as usize] = Inst::Jmp(end);
                }
            }
            Node::Group(id, inner) => {
                let g = id - 1;
                self.emit(Inst::Mark((2 * self.group_count + g) as u32))?;
                self.node(inner, depth)?;
                self.emit(Inst::Close(g as u32))?;
            }
            Node::Repeat { node, min, max } => self.repeat(node, *min, *max, depth)?,
        }
        Ok(())
    }

    fn repeat(
        &mut self,
        body: &Node,
        min: u32,
        max: Option<u32>,
        depth: usize,
    ) -> Result<(), Error> {
        // Iterations required by the minimum always run, even if empty.
        for _ in 0..min {
            self.node(body, depth)?;
        }
        // Only bodies that can match empty need the empty-iteration check.
        let nullable = analyze(body).nullable;
        let reg = if nullable { self.reg_slot(depth) } else { 0 };
        let inner_depth = if nullable { depth + 1 } else { depth };
        match max {
            None => {
                // L: split(B, E); B: [mark r] body [emptyexit r,E]; jmp L; E:
                let split = self.emit(Inst::Split(0, 0))?;
                if nullable {
                    self.emit(Inst::Mark(reg))?;
                }
                self.node(body, inner_depth)?;
                let exit = if nullable {
                    Some(self.emit(Inst::EmptyExit(reg, 0))?)
                } else {
                    None
                };
                self.emit(Inst::Jmp(split))?;
                let end = self.pc();
                self.insts[split as usize] = Inst::Split(split + 1, end);
                if let Some(e) = exit {
                    self.insts[e as usize] = Inst::EmptyExit(reg, end);
                }
            }
            Some(max) => {
                // Nested optional iterations, all leaving to the same exit.
                let extra = max - min;
                let mut splits = Vec::new();
                let mut exits = Vec::new();
                for i in 0..extra {
                    splits.push(self.emit(Inst::Split(0, 0))?);
                    if nullable {
                        self.emit(Inst::Mark(reg))?;
                    }
                    self.node(body, inner_depth)?;
                    if nullable && i + 1 < extra {
                        exits.push(self.emit(Inst::EmptyExit(reg, 0))?);
                    }
                }
                let end = self.pc();
                for s in splits {
                    self.insts[s as usize] = Inst::Split(s + 1, end);
                }
                for e in exits {
                    self.insts[e as usize] = Inst::EmptyExit(reg, end);
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::parse;

    fn prog(p: &str) -> Program {
        let parsed = parse(p.as_bytes()).unwrap();
        compile(&parsed.node, parsed.group_count).unwrap()
    }

    #[test]
    fn literal_program() {
        let p = prog("ab");
        assert_eq!(p.insts, vec![Inst::Char(b'a'), Inst::Char(b'b'), Inst::Match]);
    }

    #[test]
    fn alternation_layout() {
        let p = prog("a|b");
        assert_eq!(
            p.insts,
            vec![
                Inst::Split(1, 3),
                Inst::Char(b'a'),
                Inst::Jmp(4),
                Inst::Char(b'b'),
                Inst::Match
            ]
        );
    }

    #[test]
    fn counted_quantifier_expands() {
        let p = prog("a{3}");
        assert_eq!(p.insts.len(), 4);
        let p = prog("a{2,4}");
        // two required copies, two optional (each with a split)
        assert_eq!(p.insts.len(), 2 + 4 + 1);
    }

    #[test]
    fn nullable_loop_uses_register() {
        let p = prog("(a*)*");
        assert!(p.insts.iter().any(|i| matches!(i, Inst::EmptyExit(..))));
        let p = prog("a*");
        assert!(!p.insts.iter().any(|i| matches!(i, Inst::EmptyExit(..))));
    }

    #[test]
    fn program_size_is_limited() {
        let parsed = parse(b"((((a{100}){100}){100}){100})").unwrap();
        let err = compile(&parsed.node, parsed.group_count).unwrap_err();
        assert_eq!(err.kind(), ErrorKind::PatternTooLarge);
    }
}
