//! Compiles a syntax tree into a flat backtracking [`Program`].
//!
//! Counted quantifiers over complex atoms are expanded into copies of the
//! atom; quantifiers over a single-character atom (`a*`, `\d{2,5}`, `.+`)
//! compile to one [`Inst::Run`] instruction instead.
//!
//! Register file layout (see [`Program::nregs`]):
//!
//! | indices            | meaning                                   |
//! |--------------------|-------------------------------------------|
//! | `0 .. 2G`          | capture table: `(start, end)` per group   |
//! | `2G .. 3G`         | start offset of the group being matched   |
//! | `3G ..`            | iteration-start marks for empty-loop checks |

use crate::analysis::nullable;
use crate::ast::Node;
use crate::charset::ByteSet;
use crate::error::Error;

/// Maximum number of instructions in a compiled program.
pub const MAX_PROGRAM_SIZE: usize = 4_000_000;

/// A one-character matcher used by [`Inst::Run`].
#[derive(Clone, Copy, Debug)]
pub enum Test {
    /// Exactly this byte.
    Byte(u8),
    /// Any byte.
    Any,
    /// Any byte in `Program::sets[index]`.
    Set(u32),
}

/// One instruction of the backtracking machine.
#[derive(Clone, Copy, Debug)]
pub enum Inst {
    /// Consume this byte.
    Byte(u8),
    /// Consume any byte.
    Any,
    /// Consume a byte from `Program::sets[index]`.
    Set(u32),
    /// Succeed only at offset 0.
    Bol,
    /// Succeed only at the end of the subject.
    Eol,
    /// Continue at `first`; on failure resume at `second`.
    Split { first: u32, second: u32 },
    /// Continue at the target.
    Jmp(u32),
    /// Record the current offset as the start of group `g` (0-based).
    GroupStart(u32),
    /// Complete group `g` (0-based): captures = (recorded start, current offset).
    GroupEnd(u32),
    /// Store the current offset in mark register `slot` (a register index).
    Mark(u32),
    /// If the current offset equals register `slot`, jump to `exit`.
    Progress { slot: u32, exit: u32 },
    /// Greedily consume `min..=max` bytes matching `test`; give back one at a
    /// time on backtracking. `max == u32::MAX` means unbounded.
    Run { test: Test, min: u32, max: u32 },
    /// The whole pattern matched.
    Match,
}

/// A compiled pattern.
#[derive(Clone, Debug)]
pub struct Program {
    /// The instructions; execution starts at 0.
    pub insts: Vec<Inst>,
    /// Character sets referenced by [`Inst::Set`] and [`Test::Set`].
    pub sets: Vec<ByteSet>,
    /// Number of capture groups.
    pub groups: usize,
    /// Size of the register file.
    pub nregs: usize,
}

/// Compiles `node` (a whole pattern with `groups` capture groups).
pub fn compile(node: &Node, groups: usize) -> Result<Program, Error> {
    let mut c = Compiler { insts: Vec::new(), sets: Vec::new(), groups, marks: 0 };
    c.emit(node)?;
    c.push(Inst::Match)?;
    Ok(Program { insts: c.insts, sets: c.sets, groups, nregs: 3 * groups + c.marks })
}

struct Compiler {
    insts: Vec<Inst>,
    sets: Vec<ByteSet>,
    groups: usize,
    marks: usize,
}

impl Compiler {
    fn push(&mut self, inst: Inst) -> Result<usize, Error> {
        if self.insts.len() >= MAX_PROGRAM_SIZE {
            return Err(Error::TooLarge);
        }
        self.insts.push(inst);
        Ok(self.insts.len() - 1)
    }

    fn here(&self) -> u32 {
        self.insts.len() as u32
    }

    fn new_mark(&mut self) -> u32 {
        let slot = 3 * self.groups + self.marks;
        self.marks += 1;
        slot as u32
    }

    fn add_set(&mut self, s: &ByteSet) -> u32 {
        self.sets.push(*s);
        (self.sets.len() - 1) as u32
    }

    fn emit(&mut self, node: &Node) -> Result<(), Error> {
        match node {
            Node::Char(c) => {
                self.push(Inst::Byte(*c))?;
            }
            Node::Any => {
                self.push(Inst::Any)?;
            }
            Node::Set(s) => {
                let i = self.add_set(s);
                self.push(Inst::Set(i))?;
            }
            Node::Bol => {
                self.push(Inst::Bol)?;
            }
            Node::Eol => {
                self.push(Inst::Eol)?;
            }
            Node::Group(g, inner) => {
                self.push(Inst::GroupStart(*g as u32 - 1))?;
                self.emit(inner)?;
                self.push(Inst::GroupEnd(*g as u32 - 1))?;
            }
            Node::Concat(items) => {
                for n in items {
                    self.emit(n)?;
                }
            }
            Node::Alt(branches) => self.emit_alt(branches)?,
            Node::Repeat { node, min, max } => self.emit_repeat(node, *min, *max)?,
        }
        Ok(())
    }

    fn emit_alt(&mut self, branches: &[Node]) -> Result<(), Error> {
        let mut jumps = Vec::new();
        for (i, b) in branches.iter().enumerate() {
            if i + 1 == branches.len() {
                self.emit(b)?;
                break;
            }
            let split = self.push(Inst::Split { first: 0, second: 0 })?;
            self.emit(b)?;
            jumps.push(self.push(Inst::Jmp(0))?);
            let next = self.here();
            self.insts[split] = Inst::Split { first: split as u32 + 1, second: next };
        }
        let end = self.here();
        for j in jumps {
            self.insts[j] = Inst::Jmp(end);
        }
        Ok(())
    }

    fn emit_repeat(&mut self, x: &Node, min: u32, max: Option<u32>) -> Result<(), Error> {
        if max == Some(0) {
            return Ok(()); // the atom never runs
        }
        let single = match x {
            Node::Char(c) => Some(Test::Byte(*c)),
            Node::Any => Some(Test::Any),
            Node::Set(s) => Some(Test::Set(self.add_set(s))),
            _ => None,
        };
        if let Some(test) = single {
            self.push(Inst::Run { test, min, max: max.unwrap_or(u32::MAX) })?;
            return Ok(());
        }

        // Mandatory iterations always run, even if they match the empty string.
        for _ in 0..min {
            self.emit(x)?;
        }
        // Optional iterations: an iteration that consumes nothing ends the
        // repetition (jump to `exit`), but only if the body can be empty.
        let needs_check = nullable(x);
        let optional = match max {
            None => 1,
            Some(m) => m - min,
        };
        let mut exits = Vec::new(); // instructions whose exit target must be patched
        let mut loop_head = 0;
        for _ in 0..optional {
            let split = self.push(Inst::Split { first: 0, second: 0 })?;
            loop_head = split;
            exits.push(split);
            let slot = if needs_check {
                let slot = self.new_mark();
                self.push(Inst::Mark(slot))?;
                Some(slot)
            } else {
                None
            };
            self.emit(x)?;
            if let Some(slot) = slot {
                exits.push(self.push(Inst::Progress { slot, exit: 0 })?);
            }
        }
        if max.is_none() {
            self.push(Inst::Jmp(loop_head as u32))?;
        }
        let exit = self.here();
        for i in exits {
            self.insts[i] = match self.insts[i] {
                Inst::Split { .. } => Inst::Split { first: i as u32 + 1, second: exit },
                Inst::Progress { slot, .. } => Inst::Progress { slot, exit },
                other => other,
            };
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
    fn single_char_repeat_is_one_instruction() {
        assert_eq!(prog("a{50}").insts.len(), 2);
        assert_eq!(prog(".*").insts.len(), 2);
    }

    #[test]
    fn group_repeat_expands() {
        // GroupStart, Byte, GroupEnd per copy, plus Match.
        assert_eq!(prog("(ab){3}").insts.len(), 3 * 4 + 1);
    }

    #[test]
    fn zero_repeat_emits_nothing() {
        assert_eq!(prog("(a){0}").insts.len(), 1);
    }

    #[test]
    fn rejects_huge_expansion() {
        let p = "((((a|b){100}){100}){100}){100}";
        let parsed = parse(p.as_bytes()).unwrap();
        assert_eq!(compile(&parsed.node, parsed.group_count).unwrap_err(), Error::TooLarge);
    }
}
