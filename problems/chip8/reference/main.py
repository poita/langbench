#!/usr/bin/env python3
"""Reference CHIP-8 emulator for the langbench chip8 problem.

Reads the ROM, cycle budget and optional key schedule from stdin, runs exactly
the requested number of cycles with the semantics fixed in SPEC.md, and prints
the display followed by the register state.
"""
import sys

FONT = bytes([
    0xF0, 0x90, 0x90, 0x90, 0xF0,  # 0
    0x20, 0x60, 0x20, 0x20, 0x70,  # 1
    0xF0, 0x10, 0xF0, 0x80, 0xF0,  # 2
    0xF0, 0x10, 0xF0, 0x10, 0xF0,  # 3
    0x90, 0x90, 0xF0, 0x10, 0x10,  # 4
    0xF0, 0x80, 0xF0, 0x10, 0xF0,  # 5
    0xF0, 0x80, 0xF0, 0x90, 0xF0,  # 6
    0xF0, 0x10, 0x20, 0x40, 0x40,  # 7
    0xF0, 0x90, 0xF0, 0x90, 0xF0,  # 8
    0xF0, 0x90, 0xF0, 0x10, 0xF0,  # 9
    0xF0, 0x90, 0xF0, 0x90, 0x90,  # A
    0xE0, 0x90, 0xE0, 0x90, 0xE0,  # B
    0xF0, 0x80, 0x80, 0x80, 0xF0,  # C
    0xE0, 0x90, 0x90, 0x90, 0xE0,  # D
    0xF0, 0x80, 0xF0, 0x80, 0xF0,  # E
    0xF0, 0x80, 0xF0, 0x80, 0x80,  # F
])

FONT_BASE = 0x050
ROM_BASE = 0x200
LCG_SEED = 0x12345678


class StackFault(Exception):
    """Raised on stack overflow/underflow, which test inputs never trigger."""


def parse_input(text):
    lines = text.split("\n")
    rom_hex = lines[0].strip() if lines else ""
    cycles = int(lines[1].strip()) if len(lines) > 1 else 0
    events = []
    if len(lines) > 2:
        for tok in lines[2].split():
            c, m = tok.split(":")
            events.append((int(c), int(m, 16)))
    return bytes.fromhex(rom_hex), cycles, events


def run(rom, cycles, events):
    mem = bytearray(4096)
    mem[FONT_BASE:FONT_BASE + len(FONT)] = FONT
    mem[ROM_BASE:ROM_BASE + len(rom)] = rom
    V = [0] * 16
    stack = [0] * 16
    sp = 0
    I = 0
    pc = ROM_BASE
    dt = 0
    st = 0
    # Display is 32 rows of 64 pixels, each row stored as a 64-bit integer with
    # bit 63 being column 0 so that sprite rows can be XORed in one operation.
    disp = [0] * 32
    rng = LCG_SEED
    keys = 0
    ev_i = 0
    n_ev = len(events)
    ROW_MASK = (1 << 64) - 1

    for cycle in range(cycles):
        while ev_i < n_ev and events[ev_i][0] <= cycle:
            keys = events[ev_i][1]
            ev_i += 1

        op = (mem[pc] << 8) | mem[(pc + 1) & 0xFFF]
        pc = (pc + 2) & 0xFFF
        hi = op >> 12
        x = (op >> 8) & 0xF
        y = (op >> 4) & 0xF
        nn = op & 0xFF
        nnn = op & 0xFFF

        if hi == 0x0:
            if op == 0x00E0:
                disp = [0] * 32
            elif op == 0x00EE:
                if sp == 0:
                    raise StackFault("underflow")
                sp -= 1
                pc = stack[sp]
        elif hi == 0x1:
            pc = nnn
        elif hi == 0x2:
            if sp == 16:
                raise StackFault("overflow")
            stack[sp] = pc
            sp += 1
            pc = nnn
        elif hi == 0x3:
            if V[x] == nn:
                pc = (pc + 2) & 0xFFF
        elif hi == 0x4:
            if V[x] != nn:
                pc = (pc + 2) & 0xFFF
        elif hi == 0x5:
            if (op & 0xF) == 0 and V[x] == V[y]:
                pc = (pc + 2) & 0xFFF
        elif hi == 0x6:
            V[x] = nn
        elif hi == 0x7:
            V[x] = (V[x] + nn) & 0xFF
        elif hi == 0x8:
            sub = op & 0xF
            if sub == 0x0:
                V[x] = V[y]
            elif sub == 0x1:
                V[x] |= V[y]
            elif sub == 0x2:
                V[x] &= V[y]
            elif sub == 0x3:
                V[x] ^= V[y]
            elif sub == 0x4:
                r = V[x] + V[y]
                V[x] = r & 0xFF
                V[0xF] = 1 if r > 0xFF else 0
            elif sub == 0x5:
                r = V[x] - V[y]
                V[x] = r & 0xFF
                V[0xF] = 1 if r >= 0 else 0
            elif sub == 0x6:
                f = V[x] & 1
                V[x] >>= 1
                V[0xF] = f
            elif sub == 0x7:
                r = V[y] - V[x]
                V[x] = r & 0xFF
                V[0xF] = 1 if r >= 0 else 0
            elif sub == 0xE:
                f = (V[x] >> 7) & 1
                V[x] = (V[x] << 1) & 0xFF
                V[0xF] = f
        elif hi == 0x9:
            if (op & 0xF) == 0 and V[x] != V[y]:
                pc = (pc + 2) & 0xFFF
        elif hi == 0xA:
            I = nnn
        elif hi == 0xB:
            pc = (nnn + V[0]) & 0xFFF
        elif hi == 0xC:
            rng = (rng * 1103515245 + 12345) & 0xFFFFFFFF
            V[x] = ((rng >> 16) & 0xFF) & nn
        elif hi == 0xD:
            n = op & 0xF
            sx = V[x] & 63
            sy = V[y] & 31
            collided = 0
            for row in range(n):
                b = mem[(I + row) & 0xFFF]
                if b == 0:
                    continue
                # Rotate the 8-bit sprite row into a 64-bit display row so that
                # pixels past column 63 wrap to column 0.
                shift = 56 - sx
                if shift >= 0:
                    bits = b << shift
                else:
                    bits = ((b << (64 + shift)) & ROW_MASK) | (b >> (-shift))
                r = (sy + row) & 31
                if disp[r] & bits:
                    collided = 1
                disp[r] ^= bits
            V[0xF] = collided
        elif hi == 0xE:
            if nn == 0x9E:
                if (keys >> (V[x] & 0xF)) & 1:
                    pc = (pc + 2) & 0xFFF
            elif nn == 0xA1:
                if not (keys >> (V[x] & 0xF)) & 1:
                    pc = (pc + 2) & 0xFFF
        elif hi == 0xF:
            if nn == 0x07:
                V[x] = dt
            elif nn == 0x0A:
                if keys:
                    k = 0
                    while not (keys >> k) & 1:
                        k += 1
                    V[x] = k
                else:
                    pc = (pc - 2) & 0xFFF
            elif nn == 0x15:
                dt = V[x]
            elif nn == 0x18:
                st = V[x]
            elif nn == 0x1E:
                I = (I + V[x]) & 0xFFFF
            elif nn == 0x29:
                I = FONT_BASE + (V[x] & 0xF) * 5
            elif nn == 0x33:
                v = V[x]
                mem[I & 0xFFF] = v // 100
                mem[(I + 1) & 0xFFF] = (v // 10) % 10
                mem[(I + 2) & 0xFFF] = v % 10
            elif nn == 0x55:
                for k in range(x + 1):
                    mem[(I + k) & 0xFFF] = V[k]
            elif nn == 0x65:
                for k in range(x + 1):
                    V[k] = mem[(I + k) & 0xFFF]

        if (cycle + 1) % 8 == 0:
            if dt:
                dt -= 1
            if st:
                st -= 1

    return disp, pc, I, sp, dt, st, V


def format_state(disp, pc, I, sp, dt, st, V):
    out = []
    for row in disp:
        bits = format(row, "064b")
        out.append(bits.replace("1", "#").replace("0", "."))
    out.append("PC=%04x I=%04x SP=%d DT=%02x ST=%02x" % (pc, I, sp, dt, st))
    out.append("V=" + " ".join("%02x" % v for v in V))
    return "\n".join(out) + "\n"


def main():
    rom, cycles, events = parse_input(sys.stdin.read())
    result = run(rom, cycles, events)
    sys.stdout.write(format_state(*result))


if __name__ == "__main__":
    main()
