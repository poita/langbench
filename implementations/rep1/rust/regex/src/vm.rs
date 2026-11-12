//! The backtracking virtual machine that executes a [`Program`].
//!
//! Backtracking uses an explicit stack, so recursion depth is never an
//! issue. The stack holds three kinds of entries: pending alternatives,
//! pending "give back one byte" steps of a [`Inst::Run`], and *undo records*
//! for register writes. Popping an undo record restores the register, so
//! undoing a failed path costs time proportional to the writes it made.

use crate::compile::{Inst, Program, Test};

/// Marker for an unset register.
pub(crate) const UNSET: usize = usize::MAX;

#[derive(Clone, Copy, Debug)]
pub(crate) enum Entry {
    /// Resume at `pc` with the cursor at `pos`.
    Branch { pc: u32, pos: usize },
    /// Resume at `pc`, having given back one byte of a run that matched
    /// `lo..cur`; the cursor becomes `cur - 1` (never below `lo`).
    Run { pc: u32, lo: usize, cur: usize },
    /// Restore `regs[idx] = old`.
    Restore { idx: u32, old: usize },
}

#[inline(always)]
fn set_reg(regs: &mut [usize], stack: &mut Vec<Entry>, idx: u32, val: usize) {
    stack.push(Entry::Restore { idx, old: regs[idx as usize] });
    regs[idx as usize] = val;
}

/// Pops the stack until a resumable choice point is found, undoing register
/// writes on the way. Returns the `(pc, pos)` to resume at.
#[inline(always)]
fn backtrack(regs: &mut [usize], stack: &mut Vec<Entry>) -> Option<(usize, usize)> {
    loop {
        match stack.pop()? {
            Entry::Restore { idx, old } => regs[idx as usize] = old,
            Entry::Branch { pc, pos } => return Some((pc as usize, pos)),
            Entry::Run { pc, lo, cur } => {
                let n = cur - 1;
                if n > lo {
                    stack.push(Entry::Run { pc, lo, cur: n });
                }
                return Some((pc as usize, n));
            }
        }
    }
}

/// Runs `prog` on `s` with the match anchored at `start`.
///
/// `regs` must hold `prog.nregs` registers whose capture part is unset on
/// entry; `stack` must be empty. Returns the end offset of the match. On
/// failure all register writes have been undone and the stack is empty; on
/// success `regs` holds the captures.
pub(crate) fn run(
    prog: &Program,
    s: &[u8],
    start: usize,
    regs: &mut [usize],
    stack: &mut Vec<Entry>,
) -> Option<usize> {
    let insts = &prog.insts[..];
    let ngroups = prog.groups;
    let mut pc = 0usize;
    let mut pos = start;
    loop {
        let ok = match insts[pc] {
            Inst::Byte(c) => {
                if pos < s.len() && s[pos] == c {
                    pos += 1;
                    pc += 1;
                    true
                } else {
                    false
                }
            }
            Inst::Any => {
                if pos < s.len() {
                    pos += 1;
                    pc += 1;
                    true
                } else {
                    false
                }
            }
            Inst::Set(i) => {
                if pos < s.len() && prog.sets[i as usize].contains(s[pos]) {
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
                pos == s.len()
            }
            Inst::Split { first, second } => {
                stack.push(Entry::Branch { pc: second, pos });
                pc = first as usize;
                true
            }
            Inst::Jmp(t) => {
                pc = t as usize;
                true
            }
            Inst::GroupStart(g) => {
                set_reg(regs, stack, (2 * ngroups) as u32 + g, pos);
                pc += 1;
                true
            }
            Inst::GroupEnd(g) => {
                let gs = regs[2 * ngroups + g as usize];
                set_reg(regs, stack, 2 * g, gs);
                set_reg(regs, stack, 2 * g + 1, pos);
                pc += 1;
                true
            }
            Inst::Mark(slot) => {
                set_reg(regs, stack, slot, pos);
                pc += 1;
                true
            }
            Inst::Progress { slot, exit } => {
                if regs[slot as usize] == pos {
                    pc = exit as usize;
                } else {
                    pc += 1;
                }
                true
            }
            Inst::Run { test, min, max } => {
                let limit = if max == u32::MAX { s.len() } else { s.len().min(pos + max as usize) };
                let mut end = pos;
                match test {
                    Test::Byte(c) => {
                        while end < limit && s[end] == c {
                            end += 1;
                        }
                    }
                    Test::Any => end = limit.max(pos),
                    Test::Set(i) => {
                        let set = &prog.sets[i as usize];
                        while end < limit && set.contains(s[end]) {
                            end += 1;
                        }
                    }
                }
                let n = end - pos;
                if n < min as usize {
                    false
                } else {
                    let lo = pos + min as usize;
                    if end > lo {
                        stack.push(Entry::Run { pc: pc as u32 + 1, lo, cur: end });
                    }
                    pos = end;
                    pc += 1;
                    true
                }
            }
            Inst::Match => return Some(pos),
        };
        if !ok {
            match backtrack(regs, stack) {
                Some((p, q)) => {
                    pc = p;
                    pos = q;
                }
                None => return None,
            }
        }
    }
}
