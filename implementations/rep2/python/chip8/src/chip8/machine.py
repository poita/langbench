"""The CHIP-8 machine: state plus the fetch-decode-execute loop."""

from .constants import (
    ADDRESS_MASK,
    FONT,
    FONT_START,
    MAX_ROM_SIZE,
    MEMORY_SIZE,
    NUM_REGISTERS,
    PROGRAM_START,
    STACK_DEPTH,
)
from .display import Display
from .rng import Lcg


class Machine:
    """A deterministic CHIP-8 machine.

    Attributes are plain state: ``memory`` (bytearray of 4096), ``v`` (16
    registers), ``i``, ``pc``, ``stack`` / ``sp``, ``dt``, ``st``, ``keys``
    (a 16-bit mask, bit ``k`` set when key ``k`` is held), ``cycles`` (cycles
    completed so far), ``rng`` and ``display``.

    Opcodes are fetched and decoded from memory on every cycle; nothing is
    cached, so self-modifying programs work.
    """

    def __init__(self, rom: bytes = b"") -> None:
        self.memory = bytearray(MEMORY_SIZE)
        self.memory[FONT_START : FONT_START + len(FONT)] = FONT
        self.v = [0] * NUM_REGISTERS
        self.i = 0
        self.pc = PROGRAM_START
        self.stack = [0] * STACK_DEPTH
        self.sp = 0
        self.dt = 0
        self.st = 0
        self.keys = 0
        self.cycles = 0
        self.rng = Lcg()
        self.display = Display()
        self.load_rom(rom)

    def load_rom(self, rom: bytes) -> None:
        """Copy ``rom`` into memory at 0x200."""
        if len(rom) > MAX_ROM_SIZE:
            raise ValueError(f"ROM too large: {len(rom)} > {MAX_ROM_SIZE} bytes")
        self.memory[PROGRAM_START : PROGRAM_START + len(rom)] = rom

    def set_keys(self, mask: int) -> None:
        """Set the held-key state (bit ``k`` set means key ``k`` is down)."""
        self.keys = mask & 0xFFFF

    def step(self) -> None:
        """Execute exactly one cycle."""
        self.run(1)

    def run(self, cycles: int) -> None:
        """Execute ``cycles`` cycles with the current key state.

        The timers tick after every cycle whose 1-based number is a multiple
        of 8, counted over the machine's whole lifetime (``self.cycles``).
        State is held in locals inside the loop for speed and written back
        on exit.
        """
        mem = self.memory
        v = self.v
        stack = self.stack
        display = self.display
        draw = display.draw_sprite
        next_byte = self.rng.next_byte
        keys = self.keys
        pc = self.pc
        i = self.i
        sp = self.sp
        dt = self.dt
        st = self.st
        cycle = self.cycles
        end = cycle + cycles

        try:
            while cycle < end:
                op = (mem[pc] << 8) | mem[(pc + 1) & 0xFFF]
                pc = (pc + 2) & 0xFFF
                hi = op >> 12

                if hi == 6:
                    v[(op >> 8) & 0xF] = op & 0xFF
                elif hi == 7:
                    x = (op >> 8) & 0xF
                    v[x] = (v[x] + op) & 0xFF
                elif hi == 1:
                    pc = op & 0xFFF
                elif hi == 0xA:
                    i = op & 0xFFF
                elif hi == 8:
                    x = (op >> 8) & 0xF
                    low = op & 0xF
                    vx = v[x]
                    vy = v[(op >> 4) & 0xF]
                    if low == 0:
                        v[x] = vy
                    elif low == 1:
                        v[x] = vx | vy
                    elif low == 2:
                        v[x] = vx & vy
                    elif low == 3:
                        v[x] = vx ^ vy
                    elif low == 4:
                        total = vx + vy
                        v[x] = total & 0xFF
                        v[15] = 1 if total > 255 else 0
                    elif low == 5:
                        v[x] = (vx - vy) & 0xFF
                        v[15] = 1 if vx >= vy else 0
                    elif low == 6:
                        v[x] = vx >> 1
                        v[15] = vx & 1
                    elif low == 7:
                        v[x] = (vy - vx) & 0xFF
                        v[15] = 1 if vy >= vx else 0
                    elif low == 0xE:
                        v[x] = (vx << 1) & 0xFF
                        v[15] = vx >> 7
                elif hi == 3:
                    if v[(op >> 8) & 0xF] == op & 0xFF:
                        pc = (pc + 2) & 0xFFF
                elif hi == 4:
                    if v[(op >> 8) & 0xF] != op & 0xFF:
                        pc = (pc + 2) & 0xFFF
                elif hi == 5:
                    if op & 0xF == 0 and v[(op >> 8) & 0xF] == v[(op >> 4) & 0xF]:
                        pc = (pc + 2) & 0xFFF
                elif hi == 9:
                    if op & 0xF == 0 and v[(op >> 8) & 0xF] != v[(op >> 4) & 0xF]:
                        pc = (pc + 2) & 0xFFF
                elif hi == 0xD:
                    v[15] = draw(
                        mem, i, v[(op >> 8) & 0xF], v[(op >> 4) & 0xF], op & 0xF
                    )
                elif hi == 2:
                    stack[sp & 0xF] = pc
                    sp += 1
                    pc = op & 0xFFF
                elif hi == 0:
                    if op == 0x00E0:
                        display.clear()
                    elif op == 0x00EE:
                        sp -= 1
                        pc = stack[sp & 0xF]
                elif hi == 0xF:
                    x = (op >> 8) & 0xF
                    nn = op & 0xFF
                    if nn == 0x07:
                        v[x] = dt
                    elif nn == 0x0A:
                        if keys:
                            v[x] = (keys & -keys).bit_length() - 1
                        else:
                            pc = (pc - 2) & 0xFFF
                    elif nn == 0x15:
                        dt = v[x]
                    elif nn == 0x18:
                        st = v[x]
                    elif nn == 0x1E:
                        i = (i + v[x]) & 0xFFFF
                    elif nn == 0x29:
                        i = FONT_START + (v[x] & 0xF) * 5
                    elif nn == 0x33:
                        vx = v[x]
                        mem[i & 0xFFF] = vx // 100
                        mem[(i + 1) & 0xFFF] = (vx // 10) % 10
                        mem[(i + 2) & 0xFFF] = vx % 10
                    elif nn == 0x55:
                        for k in range(x + 1):
                            mem[(i + k) & 0xFFF] = v[k]
                    elif nn == 0x65:
                        for k in range(x + 1):
                            v[k] = mem[(i + k) & 0xFFF]
                elif hi == 0xC:
                    v[(op >> 8) & 0xF] = next_byte() & op & 0xFF
                elif hi == 0xB:
                    pc = ((op & 0xFFF) + v[0]) & 0xFFF
                else:  # 0xE
                    nn = op & 0xFF
                    if nn == 0x9E:
                        if (keys >> (v[(op >> 8) & 0xF] & 0xF)) & 1:
                            pc = (pc + 2) & 0xFFF
                    elif nn == 0xA1:
                        if not (keys >> (v[(op >> 8) & 0xF] & 0xF)) & 1:
                            pc = (pc + 2) & 0xFFF

                cycle += 1
                if not cycle & 7:
                    if dt:
                        dt -= 1
                    if st:
                        st -= 1
        finally:
            self.pc = pc
            self.i = i
            self.sp = sp
            self.dt = dt
            self.st = st
            self.cycles = cycle
