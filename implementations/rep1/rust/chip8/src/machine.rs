//! The CHIP-8 machine: state and instruction execution.

use crate::display::Display;
use crate::error::ParseError;
use crate::font::{FONT, FONT_BASE, GLYPH_SIZE};
use crate::input::MAX_ROM;
use crate::keys::KeySchedule;
use crate::rng::Lcg;

/// Address at which the ROM is loaded and execution starts.
pub const ROM_BASE: usize = 0x200;
/// Size of the address space in bytes.
pub const MEM_SIZE: usize = 0x1000;
/// Depth of the call stack.
pub const STACK_SIZE: usize = 16;

/// The complete machine state.
///
/// All fields are public so callers can inspect (or prepare) state; the
/// invariants of the specification (12-bit `pc`, 12-bit memory addressing)
/// are maintained by the execution methods.
#[derive(Debug, Clone)]
pub struct Machine {
    /// 4 KiB of memory.
    pub mem: [u8; MEM_SIZE],
    /// Registers `V0`..`VF`.
    pub v: [u8; 16],
    /// Index register (16-bit; masked to 12 bits only when addressing).
    pub i: u16,
    /// Program counter (12-bit).
    pub pc: u16,
    /// Return-address stack.
    pub stack: [u16; STACK_SIZE],
    /// Number of entries on the stack.
    pub sp: usize,
    /// Delay timer.
    pub dt: u8,
    /// Sound timer.
    pub st: u8,
    /// Keypad state; bit `k` set means key `k` is down.
    pub keys: u16,
    /// The frame buffer.
    pub display: Display,
    /// Random-number generator used by `CXNN`.
    pub rng: Lcg,
    /// Number of cycles completed so far.
    pub cycles: u64,
}

impl Machine {
    /// Creates a machine with the font loaded and `rom` placed at `0x200`.
    ///
    /// # Errors
    ///
    /// [`ParseError::RomSize`] if `rom` is empty or longer than 3584 bytes.
    pub fn new(rom: &[u8]) -> Result<Machine, ParseError> {
        if rom.is_empty() || rom.len() > MAX_ROM {
            return Err(ParseError::RomSize(rom.len()));
        }
        let mut mem = [0u8; MEM_SIZE];
        mem[FONT_BASE..FONT_BASE + FONT.len()].copy_from_slice(&FONT);
        mem[ROM_BASE..ROM_BASE + rom.len()].copy_from_slice(rom);
        Ok(Machine {
            mem,
            v: [0; 16],
            i: 0,
            pc: ROM_BASE as u16,
            stack: [0; STACK_SIZE],
            sp: 0,
            dt: 0,
            st: 0,
            keys: 0,
            display: Display::default(),
            rng: Lcg::default(),
            cycles: 0,
        })
    }

    /// Runs until `total_cycles` cycles have been completed, applying the
    /// key `schedule` (cycle numbers are absolute).
    pub fn run(&mut self, total_cycles: u64, schedule: &KeySchedule) {
        let mut cursor = schedule.cursor();
        // Skip events that are already in the past when resuming a run.
        while cursor.next_cycle().is_some_and(|c| c < self.cycles) {
            cursor.poll(cursor.next_cycle().unwrap());
        }
        while self.cycles < total_cycles {
            if let Some(mask) = cursor.poll(self.cycles) {
                self.keys = mask;
            }
            self.cycle();
        }
    }

    /// Executes one full cycle: fetch, execute, then the timer tick.
    pub fn cycle(&mut self) {
        let op = self.fetch();
        self.execute(op);
        self.cycles += 1;
        if self.cycles % 8 == 0 {
            self.dt = self.dt.saturating_sub(1);
            self.st = self.st.saturating_sub(1);
        }
    }

    #[inline]
    fn read(&self, addr: usize) -> u8 {
        self.mem[addr & 0xFFF]
    }

    #[inline]
    fn write(&mut self, addr: usize, val: u8) {
        self.mem[addr & 0xFFF] = val;
    }

    /// Fetches the opcode at `pc` and advances `pc` past it.
    fn fetch(&mut self) -> u16 {
        let pc = self.pc as usize;
        let op = (self.read(pc) as u16) << 8 | self.read(pc + 1) as u16;
        self.pc = (self.pc + 2) & 0xFFF;
        op
    }

    #[inline]
    fn skip(&mut self, cond: bool) {
        if cond {
            self.pc = (self.pc + 2) & 0xFFF;
        }
    }

    #[inline]
    fn key_down(&self, k: u8) -> bool {
        self.keys >> (k & 0xF) & 1 != 0
    }

    /// Decodes and executes a single opcode (`pc` already advanced).
    pub fn execute(&mut self, op: u16) {
        let x = (op >> 8 & 0xF) as usize;
        let y = (op >> 4 & 0xF) as usize;
        let n = (op & 0xF) as usize;
        let nn = (op & 0xFF) as u8;
        let nnn = op & 0xFFF;
        match op >> 12 {
            0x0 => match op {
                0x00E0 => self.display.clear(),
                0x00EE => {
                    self.sp = self.sp.saturating_sub(1);
                    self.pc = self.stack[self.sp % STACK_SIZE] & 0xFFF;
                }
                _ => {}
            },
            0x1 => self.pc = nnn,
            0x2 => {
                self.stack[self.sp % STACK_SIZE] = self.pc;
                self.sp = (self.sp + 1).min(STACK_SIZE);
                self.pc = nnn;
            }
            0x3 => self.skip(self.v[x] == nn),
            0x4 => self.skip(self.v[x] != nn),
            0x5 => {
                if n == 0 {
                    self.skip(self.v[x] == self.v[y]);
                }
            }
            0x6 => self.v[x] = nn,
            0x7 => self.v[x] = self.v[x].wrapping_add(nn),
            0x8 => self.alu(x, y, n),
            0x9 => {
                if n == 0 {
                    self.skip(self.v[x] != self.v[y]);
                }
            }
            0xA => self.i = nnn,
            0xB => self.pc = (nnn + self.v[0] as u16) & 0xFFF,
            0xC => {
                let r = self.rng.next_byte();
                self.v[x] = r & nn;
            }
            0xD => {
                let (sx, sy) = (self.v[x] as usize, self.v[y] as usize);
                let base = self.i as usize;
                let mem = &self.mem;
                let rows = (0..n).map(|r| mem[(base + r) & 0xFFF]);
                let hit = self.display.draw_sprite(sx, sy, rows);
                self.v[0xF] = hit as u8;
            }
            0xE => match nn {
                0x9E => self.skip(self.key_down(self.v[x])),
                0xA1 => self.skip(!self.key_down(self.v[x])),
                _ => {}
            },
            0xF => self.misc(x, nn),
            _ => unreachable!(),
        }
    }

    /// `8XYN` arithmetic/logic group. The result is written to `VX` before
    /// the flag is written to `VF`.
    fn alu(&mut self, x: usize, y: usize, n: usize) {
        let (vx, vy) = (self.v[x], self.v[y]);
        let flag = match n {
            0x0 => {
                self.v[x] = vy;
                return;
            }
            0x1 => {
                self.v[x] = vx | vy;
                return;
            }
            0x2 => {
                self.v[x] = vx & vy;
                return;
            }
            0x3 => {
                self.v[x] = vx ^ vy;
                return;
            }
            0x4 => {
                let (r, carry) = vx.overflowing_add(vy);
                self.v[x] = r;
                carry as u8
            }
            0x5 => {
                self.v[x] = vx.wrapping_sub(vy);
                (vx >= vy) as u8
            }
            0x6 => {
                self.v[x] = vx >> 1;
                vx & 1
            }
            0x7 => {
                self.v[x] = vy.wrapping_sub(vx);
                (vy >= vx) as u8
            }
            0xE => {
                self.v[x] = vx << 1;
                vx >> 7
            }
            _ => return,
        };
        self.v[0xF] = flag;
    }

    /// `FXNN` group.
    fn misc(&mut self, x: usize, nn: u8) {
        let vx = self.v[x];
        match nn {
            0x07 => self.v[x] = self.dt,
            0x0A => match self.keys.trailing_zeros() {
                k @ 0..=15 => self.v[x] = k as u8,
                _ => self.pc = (self.pc.wrapping_sub(2)) & 0xFFF,
            },
            0x15 => self.dt = vx,
            0x18 => self.st = vx,
            0x1E => self.i = self.i.wrapping_add(vx as u16),
            0x29 => self.i = (FONT_BASE + (vx & 0xF) as usize * GLYPH_SIZE) as u16,
            0x33 => {
                let i = self.i as usize;
                self.write(i, vx / 100);
                self.write(i + 1, vx / 10 % 10);
                self.write(i + 2, vx % 10);
            }
            0x55 => {
                let i = self.i as usize;
                for k in 0..=x {
                    self.write(i + k, self.v[k]);
                }
            }
            0x65 => {
                let i = self.i as usize;
                for k in 0..=x {
                    self.v[k] = self.read(i + k);
                }
            }
            _ => {}
        }
    }
}
