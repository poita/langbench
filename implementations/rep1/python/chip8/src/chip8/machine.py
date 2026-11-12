"""The CHIP-8 virtual machine.

The :class:`Machine` implements the deterministic CHIP-8 variant described in
the project specification: 4 KiB of memory, sixteen 8-bit registers, a 16-entry
call stack, two timers, a 64x32 monochrome display, a 16-key keypad and a
32-bit linear congruential random number generator.

Every cycle fetches and decodes the opcode from memory; nothing is cached, so
self-modifying programs behave correctly.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from typing import NamedTuple

from .font import FONT, FONT_ADDRESS, GLYPH_SIZE

MEMORY_SIZE = 0x1000
PROGRAM_START = 0x200
MAX_ROM_SIZE = MEMORY_SIZE - PROGRAM_START
DISPLAY_WIDTH = 64
DISPLAY_HEIGHT = 32
STACK_SIZE = 16
TIMER_PERIOD = 8
"""Timers are decremented once every this many completed cycles."""

RNG_SEED = 0x12345678
_RNG_MULTIPLIER = 1103515245
_RNG_INCREMENT = 12345


class KeyEvent(NamedTuple):
    """A change of keypad state.

    ``mask`` has bit ``k`` set when key ``k`` is held down. The event takes
    effect immediately before cycle number ``cycle`` executes.
    """

    cycle: int
    mask: int


class Machine:
    """A CHIP-8 machine.

    Attributes:
        memory: 4096 bytes of RAM.
        v: the sixteen 8-bit registers ``V0``..``VF``.
        i: the 16-bit index register.
        pc: the 12-bit program counter.
        stack: return addresses; ``len(stack)`` is the stack pointer.
        dt, st: delay and sound timers.
        keys: 16-bit keypad state (bit ``k`` set means key ``k`` is down).
        rng_state: current 32-bit state of the random number generator.
        display: 64*32 pixels, row-major, each ``0`` or ``1``.
        cycles: number of cycles completed so far.
    """

    def __init__(self, rom: bytes | bytearray | Sequence[int] = b"", seed: int = RNG_SEED) -> None:
        self.memory = bytearray(MEMORY_SIZE)
        self.memory[FONT_ADDRESS : FONT_ADDRESS + len(FONT)] = FONT
        self.v = [0] * 16
        self.i = 0
        self.pc = PROGRAM_START
        self.stack: list[int] = []
        self.dt = 0
        self.st = 0
        self.keys = 0
        self.rng_state = seed & 0xFFFFFFFF
        self.display = bytearray(DISPLAY_WIDTH * DISPLAY_HEIGHT)
        self.cycles = 0
        self._dispatch = (
            self._op_0, self._op_1, self._op_2, self._op_3,
            self._op_4, self._op_5, self._op_6, self._op_7,
            self._op_8, self._op_9, self._op_a, self._op_b,
            self._op_c, self._op_d, self._op_e, self._op_f,
        )  # fmt: skip
        self._alu = (
            self._alu_load, self._alu_or, self._alu_and, self._alu_xor,
            self._alu_add, self._alu_sub, self._alu_shr, self._alu_subn,
            self._alu_nop, self._alu_nop, self._alu_nop, self._alu_nop,
            self._alu_nop, self._alu_nop, self._alu_shl, self._alu_nop,
        )  # fmt: skip
        self._misc = {
            0x07: self._f_get_delay,
            0x0A: self._f_wait_key,
            0x15: self._f_set_delay,
            0x18: self._f_set_sound,
            0x1E: self._f_add_i,
            0x29: self._f_font,
            0x33: self._f_bcd,
            0x55: self._f_store,
            0x65: self._f_load,
        }
        if len(rom):
            self.load_rom(rom)

    # ------------------------------------------------------------------ API

    def load_rom(self, rom: bytes | bytearray | Sequence[int]) -> None:
        """Copy ``rom`` into memory at ``0x200``.

        Raises:
            ValueError: if the ROM does not fit in memory.
        """
        data = bytes(rom)
        if len(data) > MAX_ROM_SIZE:
            raise ValueError(f"ROM is {len(data)} bytes; the maximum is {MAX_ROM_SIZE}")
        self.memory[PROGRAM_START : PROGRAM_START + len(data)] = data

    def pixel(self, x: int, y: int) -> bool:
        """Return whether the pixel at column ``x``, row ``y`` is lit."""
        return bool(self.display[y * DISPLAY_WIDTH + x])

    def step(self) -> None:
        """Execute one cycle (fetch, execute, timer tick), without key events."""
        memory = self.memory
        pc = self.pc
        op = (memory[pc] << 8) | memory[(pc + 1) & 0xFFF]
        self.pc = (pc + 2) & 0xFFF
        self._dispatch[op >> 12](op)
        self.cycles += 1
        if not self.cycles & (TIMER_PERIOD - 1):
            if self.dt:
                self.dt -= 1
            if self.st:
                self.st -= 1

    def run(self, cycles: int, key_schedule: Iterable[KeyEvent | tuple[int, int]] = ()) -> None:
        """Execute ``cycles`` further cycles.

        ``key_schedule`` is an iterable of ``(cycle, mask)`` events in strictly
        increasing order of absolute cycle number (the cycle counter is
        :attr:`cycles`). Each event is applied immediately before its cycle
        executes; events are consumed in order, so scheduling costs O(1) per
        cycle.
        """
        events = iter(key_schedule)
        nxt = next(events, None)
        step = self.step
        end = self.cycles + cycles
        while self.cycles < end:
            now = self.cycles
            if nxt is not None:
                if nxt[0] <= now:
                    self.keys = nxt[1]
                    nxt = next(events, None)
                    continue
                # Run until the next event is due (or the budget ends).
                stop = min(end, nxt[0])
            else:
                stop = end
            while self.cycles < stop:
                step()

    # ------------------------------------------------------------ top level

    def _op_0(self, op: int) -> None:
        if op == 0x00E0:
            self.display = bytearray(DISPLAY_WIDTH * DISPLAY_HEIGHT)
        elif op == 0x00EE:
            self.pc = self.stack.pop()

    def _op_1(self, op: int) -> None:
        self.pc = op & 0xFFF

    def _op_2(self, op: int) -> None:
        self.stack.append(self.pc)
        self.pc = op & 0xFFF

    def _op_3(self, op: int) -> None:
        if self.v[(op >> 8) & 0xF] == op & 0xFF:
            self.pc = (self.pc + 2) & 0xFFF

    def _op_4(self, op: int) -> None:
        if self.v[(op >> 8) & 0xF] != op & 0xFF:
            self.pc = (self.pc + 2) & 0xFFF

    def _op_5(self, op: int) -> None:
        if not op & 0xF:
            v = self.v
            if v[(op >> 8) & 0xF] == v[(op >> 4) & 0xF]:
                self.pc = (self.pc + 2) & 0xFFF

    def _op_6(self, op: int) -> None:
        self.v[(op >> 8) & 0xF] = op & 0xFF

    def _op_7(self, op: int) -> None:
        x = (op >> 8) & 0xF
        self.v[x] = (self.v[x] + op) & 0xFF

    def _op_8(self, op: int) -> None:
        self._alu[op & 0xF](op)

    def _op_9(self, op: int) -> None:
        if not op & 0xF:
            v = self.v
            if v[(op >> 8) & 0xF] != v[(op >> 4) & 0xF]:
                self.pc = (self.pc + 2) & 0xFFF

    def _op_a(self, op: int) -> None:
        self.i = op & 0xFFF

    def _op_b(self, op: int) -> None:
        self.pc = ((op & 0xFFF) + self.v[0]) & 0xFFF

    def _op_c(self, op: int) -> None:
        state = (self.rng_state * _RNG_MULTIPLIER + _RNG_INCREMENT) & 0xFFFFFFFF
        self.rng_state = state
        self.v[(op >> 8) & 0xF] = (state >> 16) & op & 0xFF

    def _op_d(self, op: int) -> None:
        v = self.v
        memory = self.memory
        display = self.display
        sx = v[(op >> 8) & 0xF] & 63
        sy = v[(op >> 4) & 0xF] & 31
        i = self.i
        collision = 0
        for row in range(op & 0xF):
            byte = memory[(i + row) & 0xFFF]
            if not byte:
                continue
            base = ((sy + row) & 31) * DISPLAY_WIDTH
            for bit in range(8):
                if byte & (0x80 >> bit):
                    idx = base + ((sx + bit) & 63)
                    if display[idx]:
                        collision = 1
                    display[idx] ^= 1
        v[0xF] = collision

    def _op_e(self, op: int) -> None:
        sub = op & 0xFF
        if sub == 0x9E:
            if (self.keys >> (self.v[(op >> 8) & 0xF] & 0xF)) & 1:
                self.pc = (self.pc + 2) & 0xFFF
        elif sub == 0xA1:
            if not (self.keys >> (self.v[(op >> 8) & 0xF] & 0xF)) & 1:
                self.pc = (self.pc + 2) & 0xFFF

    def _op_f(self, op: int) -> None:
        handler = self._misc.get(op & 0xFF)
        if handler is not None:
            handler((op >> 8) & 0xF)

    # --------------------------------------------------------- 8XYn (ALU)

    def _alu_nop(self, op: int) -> None:
        pass

    def _alu_load(self, op: int) -> None:
        self.v[(op >> 8) & 0xF] = self.v[(op >> 4) & 0xF]

    def _alu_or(self, op: int) -> None:
        v = self.v
        v[(op >> 8) & 0xF] |= v[(op >> 4) & 0xF]

    def _alu_and(self, op: int) -> None:
        v = self.v
        v[(op >> 8) & 0xF] &= v[(op >> 4) & 0xF]

    def _alu_xor(self, op: int) -> None:
        v = self.v
        v[(op >> 8) & 0xF] ^= v[(op >> 4) & 0xF]

    def _alu_add(self, op: int) -> None:
        v = self.v
        x = (op >> 8) & 0xF
        total = v[x] + v[(op >> 4) & 0xF]
        v[x] = total & 0xFF
        v[0xF] = 1 if total > 255 else 0

    def _alu_sub(self, op: int) -> None:
        v = self.v
        x = (op >> 8) & 0xF
        vx = v[x]
        vy = v[(op >> 4) & 0xF]
        v[x] = (vx - vy) & 0xFF
        v[0xF] = 1 if vx >= vy else 0

    def _alu_subn(self, op: int) -> None:
        v = self.v
        x = (op >> 8) & 0xF
        vx = v[x]
        vy = v[(op >> 4) & 0xF]
        v[x] = (vy - vx) & 0xFF
        v[0xF] = 1 if vy >= vx else 0

    def _alu_shr(self, op: int) -> None:
        v = self.v
        x = (op >> 8) & 0xF
        flag = v[x] & 1
        v[x] >>= 1
        v[0xF] = flag

    def _alu_shl(self, op: int) -> None:
        v = self.v
        x = (op >> 8) & 0xF
        flag = (v[x] >> 7) & 1
        v[x] = (v[x] << 1) & 0xFF
        v[0xF] = flag

    # ------------------------------------------------------- FXnn handlers
    # Each receives the register index X.

    def _f_get_delay(self, x: int) -> None:
        self.v[x] = self.dt

    def _f_wait_key(self, x: int) -> None:
        keys = self.keys
        if keys:
            self.v[x] = (keys & -keys).bit_length() - 1
        else:
            self.pc = (self.pc - 2) & 0xFFF

    def _f_set_delay(self, x: int) -> None:
        self.dt = self.v[x]

    def _f_set_sound(self, x: int) -> None:
        self.st = self.v[x]

    def _f_add_i(self, x: int) -> None:
        self.i = (self.i + self.v[x]) & 0xFFFF

    def _f_font(self, x: int) -> None:
        self.i = FONT_ADDRESS + (self.v[x] & 0xF) * GLYPH_SIZE

    def _f_bcd(self, x: int) -> None:
        value = self.v[x]
        memory = self.memory
        i = self.i
        memory[i & 0xFFF] = value // 100
        memory[(i + 1) & 0xFFF] = (value // 10) % 10
        memory[(i + 2) & 0xFFF] = value % 10

    def _f_store(self, x: int) -> None:
        memory = self.memory
        v = self.v
        i = self.i
        for k in range(x + 1):
            memory[(i + k) & 0xFFF] = v[k]

    def _f_load(self, x: int) -> None:
        memory = self.memory
        v = self.v
        i = self.i
        for k in range(x + 1):
            v[k] = memory[(i + k) & 0xFFF]
