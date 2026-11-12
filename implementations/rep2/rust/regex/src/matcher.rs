//! The backtracking virtual machine.
//!
//! The machine walks the compiled [`Program`] with an explicit backtrack
//! stack, so recursion depth is never a concern. The stack holds two kinds
//! of frames: *branches* (a pc/position to resume from) and *restores* (an
//! old slot value to put back). Popping past a restore undoes exactly one
//! write, so undoing a failed path costs time proportional to the writes
//! made on it.

use crate::compiler::{Inst, Program};

const UNSET: usize = usize::MAX;

#[derive(Clone, Copy)]
enum Frame {
    Branch { pc: u32, pos: usize },
    Restore { slot: u32, old: usize },
}

/// Reusable matcher state for one program: the slot table and backtrack
/// stack are kept between searches to avoid reallocation.
#[derive(Debug)]
pub struct Machine {
    slots: Vec<usize>,
    stack: Vec<Frame>,
}

impl std::fmt::Debug for Frame {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Frame::Branch { pc, pos } => write!(f, "Branch({pc},{pos})"),
            Frame::Restore { slot, old } => write!(f, "Restore({slot},{old})"),
        }
    }
}

impl Machine {
    pub fn new(prog: &Program) -> Self {
        Machine {
            slots: vec![UNSET; prog.slot_count],
            stack: Vec::new(),
        }
    }

    /// Value of capture group `g` (0-based) after a successful [`run`]
    /// and before the next one.
    ///
    /// [`run`]: Machine::run
    pub fn capture(&self, g: usize) -> Option<(usize, usize)> {
        let s = self.slots[2 * g];
        let e = self.slots[2 * g + 1];
        if s == UNSET {
            None
        } else {
            Some((s, e))
        }
    }

    /// Tries to match `prog` at exactly `start`. On success returns the end
    /// of the match; capture values stay readable through [`capture`] until
    /// [`reset`] is called. On failure all state has been restored.
    ///
    /// [`capture`]: Machine::capture
    /// [`reset`]: Machine::reset
    pub fn run(&mut self, prog: &Program, subject: &[u8], start: usize) -> Option<usize> {
        let insts = &prog.insts[..];
        let len = subject.len();
        let mut pc = 0usize;
        let mut pos = start;
        debug_assert!(self.stack.is_empty());
        loop {
            let ok = match insts[pc] {
                Inst::Char(c) => {
                    if pos < len && subject[pos] == c {
                        pos += 1;
                        pc += 1;
                        true
                    } else {
                        false
                    }
                }
                Inst::Any => {
                    if pos < len {
                        pos += 1;
                        pc += 1;
                        true
                    } else {
                        false
                    }
                }
                Inst::Set(i) => {
                    if pos < len && prog.sets[i as usize].contains(subject[pos]) {
                        pos += 1;
                        pc += 1;
                        true
                    } else {
                        false
                    }
                }
                Inst::Bol => {
                    pc += 1;
                    pos == 0
                }
                Inst::Eol => {
                    pc += 1;
                    pos == len
                }
                Inst::Split(a, b) => {
                    self.stack.push(Frame::Branch { pc: b, pos });
                    pc = a as usize;
                    true
                }
                Inst::Jmp(t) => {
                    pc = t as usize;
                    true
                }
                Inst::Mark(slot) => {
                    self.write(slot as usize, pos);
                    pc += 1;
                    true
                }
                Inst::Close(g) => {
                    let g = g as usize;
                    let open = self.slots[2 * prog.group_count + g];
                    self.write(2 * g, open);
                    self.write(2 * g + 1, pos);
                    pc += 1;
                    true
                }
                Inst::EmptyExit(slot, target) => {
                    if self.slots[slot as usize] == pos {
                        pc = target as usize;
                    } else {
                        pc += 1;
                    }
                    true
                }
                Inst::Match => return Some(pos),
            };
            if !ok {
                match self.backtrack() {
                    Some((p, q)) => {
                        pc = p;
                        pos = q;
                    }
                    None => return None,
                }
            }
        }
    }

    /// Writes a slot, logging the old value so it can be undone.
    #[inline]
    fn write(&mut self, slot: usize, value: usize) {
        let old = self.slots[slot];
        self.stack.push(Frame::Restore {
            slot: slot as u32,
            old,
        });
        self.slots[slot] = value;
    }

    /// Pops frames, undoing writes, until a branch is found.
    #[inline]
    fn backtrack(&mut self) -> Option<(usize, usize)> {
        while let Some(f) = self.stack.pop() {
            match f {
                Frame::Restore { slot, old } => self.slots[slot as usize] = old,
                Frame::Branch { pc, pos } => return Some((pc as usize, pos)),
            }
        }
        None
    }

    /// Discards the remaining backtrack state after a successful run and
    /// restores every slot to unset.
    pub fn reset(&mut self) {
        while let Some(f) = self.stack.pop() {
            if let Frame::Restore { slot, old } = f {
                self.slots[slot as usize] = old;
            }
        }
    }
}
