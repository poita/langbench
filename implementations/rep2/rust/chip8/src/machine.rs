//! The CHIP-8 machine: memory, registers, timers and the instruction set.

use crate::display::Display;
use crate::error::RomError;
use crate::font::{FONT, FONT_START, GLYPH_SIZE};
use crate::keys::KeySchedule;
use crate::rng::Lcg;

/// Size of the address space in bytes.
pub const MEMORY_SIZE: usize = 4096;
/// Address at which ROMs are loaded and execution starts.
pub const PROGRAM_START: usize = 0x200;
/// Number of return-address slots on the call stack.
pub const STACK_SIZE: usize = 16;
/// Timers are decremented once every this many completed cycles.
pub const TIMER_PERIOD: u64 = 8;

const ADDR_MASK: usize = 0xFFF;

/// A complete CHIP-8 machine.
///
/// Create one with [`Machine::new`], load a program with
/// [`Machine::load_rom`], then execute it with [`Machine::run`] (or drive it
/// manually with [`Machine::set_keys`] and [`Machine::step`]).
///
/// Behaviour on stack overflow (a 17th push) or underflow (a pop with an empty
/// stack) is unspecified; this implementation ignores the push's store /
/// the pop's return but never panics.
#[derive(Clone)]
pub struct Machine {
    mem: [u8; MEMORY_SIZE],
    v: [u8; 16],
    i: u16,
    pc: u16,
    stack: [u16; STACK_SIZE],
    sp: usize,
    dt: u8,
    st: u8,
    keys: u16,
    rng: Lcg,
    display: Display,
    cycles: u64,
}

impl Machine {
    /// Creates a machine in its power-on state: font loaded, `PC = 0x200`.
    pub fn new() -> Self {
        let mut mem = [0u8; MEMORY_SIZE];
        mem[FONT_START..FONT_START + FONT.len()].copy_from_slice(&FONT);
        Self {
            mem,
            v: [0; 16],
            i: 0,
            pc: PROGRAM_START as u16,
            stack: [0; STACK_SIZE],
            sp: 0,
            dt: 0,
            st: 0,
            keys: 0,
            rng: Lcg::new(),
            display: Display::new(),
            cycles: 0,
        }
    }

    /// Copies `rom` into memory starting at `0x200`.
    pub fn load_rom(&mut self, rom: &[u8]) -> Result<(), RomError> {
        let max = MEMORY_SIZE - PROGRAM_START;
        if rom.len() > max {
            return Err(RomError::TooLarge { len: rom.len(), max });
        }
        self.mem[PROGRAM_START..PROGRAM_START + rom.len()].copy_from_slice(rom);
        Ok(())
    }

    /// Program counter (12 bits).
    pub fn pc(&self) -> u16 {
        self.pc
    }
    /// Index register (16 bits).
    pub fn index(&self) -> u16 {
        self.i
    }
    /// Stack pointer: the number of entries on the stack.
    pub fn sp(&self) -> usize {
        self.sp
    }
    /// Delay timer.
    pub fn delay_timer(&self) -> u8 {
        self.dt
    }
    /// Sound timer.
    pub fn sound_timer(&self) -> u8 {
        self.st
    }
    /// Registers `V0`..`VF`.
    pub fn registers(&self) -> &[u8; 16] {
        &self.v
    }
    /// All of memory.
    pub fn memory(&self) -> &[u8; MEMORY_SIZE] {
        &self.mem
    }
    /// The frame buffer.
    pub fn display(&self) -> &Display {
        &self.display
    }
    /// Number of cycles executed so far.
    pub fn cycles(&self) -> u64 {
        self.cycles
    }
    /// The current key state (bit `k` set = key `k` down).
    pub fn keys(&self) -> u16 {
        self.keys
    }

    /// Sets the key state (bit `k` set = key `k` down).
    pub fn set_keys(&mut self, mask: u16) {
        self.keys = mask;
    }

    /// Executes `cycles` cycles in total (counting from the machine's current
    /// cycle count), applying events from `schedule` before the cycle they
    /// name. Events are consumed in order, so the cost per cycle is O(1).
    ///
    /// The schedule's cycle numbers are absolute, so this is meant to be
    /// called once on a fresh machine.
    pub fn run(&mut self, cycles: u64, schedule: &KeySchedule) {
        let mut events = schedule.events().iter().peekable();
        while self.cycles < cycles {
            while let Some(ev) = events.next_if(|e| e.cycle <= self.cycles) {
                self.keys = ev.mask;
            }
            let end = events.peek().map_or(cycles, |e| e.cycle.min(cycles));
            while self.cycles < end {
                self.step();
            }
        }
    }

    /// Executes exactly one cycle (fetch, execute, timer tick). Key events are
    /// not applied here; use [`Machine::set_keys`] before calling.
    #[inline]
    pub fn step(&mut self) {
        let pc = self.pc as usize;
        let op = (u16::from(self.mem[pc]) << 8) | u16::from(self.mem[(pc + 1) & ADDR_MASK]);
        self.pc = ((pc + 2) & ADDR_MASK) as u16;
        self.execute(op);
        self.cycles += 1;
        if self.cycles.is_multiple_of(TIMER_PERIOD) {
            self.dt = self.dt.saturating_sub(1);
            self.st = self.st.saturating_sub(1);
        }
    }

    #[inline]
    fn skip(&mut self) {
        self.pc = (self.pc + 2) & ADDR_MASK as u16;
    }

    #[inline]
    fn jump(&mut self, addr: u16) {
        self.pc = addr & ADDR_MASK as u16;
    }

    #[inline]
    fn execute(&mut self, op: u16) {
        let x = ((op >> 8) & 0xF) as usize;
        let y = ((op >> 4) & 0xF) as usize;
        let n = (op & 0xF) as u8;
        let nn = (op & 0xFF) as u8;
        let nnn = op & 0xFFF;

        match op >> 12 {
            0x0 => match op {
                0x00E0 => self.display.clear(),
                0x00EE if self.sp > 0 => {
                    self.sp -= 1;
                    self.pc = self.stack[self.sp];
                }
                _ => {}
            },
            0x1 => self.jump(nnn),
            0x2 => {
                if self.sp < STACK_SIZE {
                    self.stack[self.sp] = self.pc;
                    self.sp += 1;
                }
                self.jump(nnn);
            }
            0x3 => {
                if self.v[x] == nn {
                    self.skip();
                }
            }
            0x4 => {
                if self.v[x] != nn {
                    self.skip();
                }
            }
            0x5 => {
                if n == 0 && self.v[x] == self.v[y] {
                    self.skip();
                }
            }
            0x6 => self.v[x] = nn,
            0x7 => self.v[x] = self.v[x].wrapping_add(nn),
            0x8 => self.alu(x, y, n),
            0x9 => {
                if n == 0 && self.v[x] != self.v[y] {
                    self.skip();
                }
            }
            0xA => self.i = nnn,
            0xB => self.jump(nnn + u16::from(self.v[0])),
            0xC => self.v[x] = self.rng.next_byte() & nn,
            0xD => self.draw(x, y, n),
            0xE => {
                let down = (self.keys >> (self.v[x] & 0xF)) & 1 != 0;
                match nn {
                    0x9E if down => self.skip(),
                    0xA1 if !down => self.skip(),
                    _ => {}
                }
            }
            _ => self.misc(x, nn),
        }
    }

    #[inline]
    fn alu(&mut self, x: usize, y: usize, n: u8) {
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
                let (sum, carry) = vx.overflowing_add(vy);
                self.v[x] = sum;
                u8::from(carry)
            }
            0x5 => {
                self.v[x] = vx.wrapping_sub(vy);
                u8::from(vx >= vy)
            }
            0x6 => {
                self.v[x] = vx >> 1;
                vx & 1
            }
            0x7 => {
                self.v[x] = vy.wrapping_sub(vx);
                u8::from(vy >= vx)
            }
            0xE => {
                self.v[x] = vx << 1;
                vx >> 7
            }
            _ => return,
        };
        // The flag is written after the result so it wins when X = F.
        self.v[0xF] = flag;
    }

    fn draw(&mut self, x: usize, y: usize, n: u8) {
        let sx = usize::from(self.v[x] & 63);
        let sy = usize::from(self.v[y] & 31);
        let mut collision = false;
        for row in 0..usize::from(n) {
            let byte = self.mem[(usize::from(self.i) + row) & ADDR_MASK];
            for bit in 0..8 {
                if (byte >> (7 - bit)) & 1 != 0 {
                    collision |= self.display.toggle(sx + bit, sy + row);
                }
            }
        }
        self.v[0xF] = u8::from(collision);
    }

    fn misc(&mut self, x: usize, nn: u8) {
        let i = usize::from(self.i);
        let vx = self.v[x];
        match nn {
            0x07 => self.v[x] = self.dt,
            0x0A => {
                if self.keys != 0 {
                    self.v[x] = self.keys.trailing_zeros() as u8;
                } else {
                    self.pc = (self.pc.wrapping_sub(2)) & ADDR_MASK as u16;
                }
            }
            0x15 => self.dt = vx,
            0x18 => self.st = vx,
            0x1E => self.i = self.i.wrapping_add(u16::from(vx)),
            0x29 => self.i = (FONT_START + usize::from(vx & 0xF) * GLYPH_SIZE) as u16,
            0x33 => {
                self.mem[i & ADDR_MASK] = vx / 100;
                self.mem[(i + 1) & ADDR_MASK] = (vx / 10) % 10;
                self.mem[(i + 2) & ADDR_MASK] = vx % 10;
            }
            0x55 => {
                for k in 0..=x {
                    self.mem[(i + k) & ADDR_MASK] = self.v[k];
                }
            }
            0x65 => {
                for k in 0..=x {
                    self.v[k] = self.mem[(i + k) & ADDR_MASK];
                }
            }
            _ => {}
        }
    }
}

impl Default for Machine {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for Machine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Machine")
            .field("pc", &self.pc)
            .field("i", &self.i)
            .field("sp", &self.sp)
            .field("dt", &self.dt)
            .field("st", &self.st)
            .field("v", &self.v)
            .field("cycles", &self.cycles)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_ops(ops: &[u16], cycles: u64) -> Machine {
        let rom: Vec<u8> = ops.iter().flat_map(|o| o.to_be_bytes()).collect();
        let mut m = Machine::new();
        m.load_rom(&rom).unwrap();
        m.run(cycles, &KeySchedule::new());
        m
    }

    #[test]
    fn flag_wins_when_x_is_f() {
        // VF = 0xFF; VF += VF -> 0xFE then flag 1.
        let m = run_ops(&[0x6FFF, 0x8FF4], 2);
        assert_eq!(m.registers()[0xF], 1);
    }

    #[test]
    fn subtract_flags() {
        // V0=5, V1=5; V0 -= V1 -> 0, VF=1 (no borrow)
        let m = run_ops(&[0x6005, 0x6105, 0x8015], 3);
        assert_eq!((m.registers()[0], m.registers()[0xF]), (0, 1));
        // V0=3, V1=5; V0 = V1 - V0 = 2, VF=1
        let m = run_ops(&[0x6003, 0x6105, 0x8017], 3);
        assert_eq!((m.registers()[0], m.registers()[0xF]), (2, 1));
        // V0=3, V1=5; V0 -= V1 = 0xFE, VF=0
        let m = run_ops(&[0x6003, 0x6105, 0x8015], 3);
        assert_eq!((m.registers()[0], m.registers()[0xF]), (0xFE, 0));
    }

    #[test]
    fn shifts_ignore_vy() {
        let m = run_ops(&[0x6003, 0x61FF, 0x8016], 3);
        assert_eq!((m.registers()[0], m.registers()[0xF]), (1, 1));
        let m = run_ops(&[0x6081, 0x8E0E], 2);
        assert_eq!(m.registers()[0], 0x81);
        let m = run_ops(&[0x6081, 0x800E], 2);
        assert_eq!((m.registers()[0], m.registers()[0xF]), (2, 1));
    }

    #[test]
    fn pc_wraps_at_end_of_memory() {
        let mut m = Machine::new();
        m.load_rom(&[0x1F, 0xFF]).unwrap(); // jump to 0xFFF
        m.step();
        assert_eq!(m.pc(), 0xFFF);
        m.step(); // fetch 0x00 (mem[0xFFF]) : 0x00 (mem[0])
        assert_eq!(m.pc(), 0x001);
    }

    #[test]
    fn call_and_return() {
        let m = run_ops(&[0x2204, 0x1202, 0x00EE], 2);
        assert_eq!(m.sp(), 0);
        let m = run_ops(&[0x2204, 0x1202, 0x6001], 1);
        assert_eq!((m.sp(), m.pc()), (1, 0x204));
    }

    #[test]
    fn bcd_and_register_transfer() {
        let m = run_ops(&[0x60FE, 0xA300, 0xF033, 0xF265], 4);
        assert_eq!(&m.memory()[0x300..0x303], &[2, 5, 4]);
        assert_eq!(&m.registers()[..3], &[2, 5, 4]);
    }

    #[test]
    fn timers_tick_after_eighth_cycle() {
        // V0 = 3; DT = V0 (cycle 1); then loop.
        let m = run_ops(&[0x6003, 0xF015, 0x1204], 8);
        assert_eq!(m.delay_timer(), 2);
    }

    #[test]
    fn key_events_apply_before_their_cycle() {
        let rom = [0xF0, 0x0A, 0x12, 0x02]; // wait for key, then loop
        let mut m = Machine::new();
        m.load_rom(&rom).unwrap();
        let sched = KeySchedule::from_events(vec![crate::KeyEvent { cycle: 2, mask: 0x0020 }]).unwrap();
        m.run(2, &sched);
        assert_eq!(m.registers()[0], 0);
        let mut m2 = Machine::new();
        m2.load_rom(&rom).unwrap();
        m2.run(3, &sched);
        assert_eq!(m2.registers()[0], 5);
    }
}
