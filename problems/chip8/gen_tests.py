#!/usr/bin/env python3
"""Generate tests/*.in and tests/*.out for chip8.

ROMs are written in a small Cowgod-style assembly and assembled here, or built
directly as random instruction streams. Expected outputs come from
reference/main.py. Where an outcome can be computed independently of the
emulator (ALU results, timers, BCD digits, Rule 90 patterns, the prime sieve)
it is asserted against the reference output as a cross-check.
"""
import importlib.util
import os
import random
import sys

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
REF = os.path.join(HERE, "reference", "main.py")

spec = importlib.util.spec_from_file_location("ref", REF)
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)


# ---------------------------------------------------------------------------
# Assembler
# ---------------------------------------------------------------------------

def _reg(tok):
    tok = tok.strip().upper()
    if len(tok) == 2 and tok[0] == "V" and tok[1] in "0123456789ABCDEF":
        return int(tok[1], 16)
    return None


def _num(tok, labels):
    tok = tok.strip()
    if tok in labels:
        return labels[tok]
    return int(tok, 0)


def assemble(src):
    """Two-pass assembler. Returns ROM bytes (origin 0x200)."""
    lines = []
    for raw in src.split("\n"):
        line = raw.split(";", 1)[0].strip()
        if not line:
            continue
        while ":" in line:
            label, rest = line.split(":", 1)
            lines.append(("label", label.strip()))
            line = rest.strip()
        if line:
            lines.append(("inst", line))

    def size_of(text):
        mnem = text.split(None, 1)[0].upper()
        if mnem == "DB":
            return len(text.split(None, 1)[1].split(","))
        return 2

    labels = {}
    addr = 0x200
    for kind, text in lines:
        if kind == "label":
            labels[text] = addr
        else:
            addr += size_of(text)

    out = bytearray()

    def emit(word):
        out.append((word >> 8) & 0xFF)
        out.append(word & 0xFF)

    for kind, text in lines:
        if kind == "label":
            continue
        parts = text.split(None, 1)
        mnem = parts[0].upper()
        ops = [p.strip() for p in parts[1].split(",")] if len(parts) > 1 else []
        up = [o.upper() for o in ops]
        if mnem == "DB":
            for o in ops:
                out.append(_num(o, labels) & 0xFF)
            continue
        if mnem == "DW":
            emit(_num(ops[0], labels) & 0xFFFF)
            continue
        if mnem == "CLS":
            emit(0x00E0)
        elif mnem == "RET":
            emit(0x00EE)
        elif mnem == "SYS":
            emit(0x0000 | (_num(ops[0], labels) & 0xFFF))
        elif mnem == "JP":
            if len(ops) == 2:
                assert up[0] == "V0"
                emit(0xB000 | (_num(ops[1], labels) & 0xFFF))
            else:
                emit(0x1000 | (_num(ops[0], labels) & 0xFFF))
        elif mnem == "CALL":
            emit(0x2000 | (_num(ops[0], labels) & 0xFFF))
        elif mnem == "SE":
            x = _reg(ops[0])
            y = _reg(ops[1])
            if y is None:
                emit(0x3000 | (x << 8) | (_num(ops[1], labels) & 0xFF))
            else:
                emit(0x5000 | (x << 8) | (y << 4))
        elif mnem == "SNE":
            x = _reg(ops[0])
            y = _reg(ops[1])
            if y is None:
                emit(0x4000 | (x << 8) | (_num(ops[1], labels) & 0xFF))
            else:
                emit(0x9000 | (x << 8) | (y << 4))
        elif mnem == "LD":
            a, b = up
            if a == "I":
                emit(0xA000 | (_num(ops[1], labels) & 0xFFF))
            elif a == "DT":
                emit(0xF015 | (_reg(b) << 8))
            elif a == "ST":
                emit(0xF018 | (_reg(b) << 8))
            elif a == "F":
                emit(0xF029 | (_reg(b) << 8))
            elif a == "B":
                emit(0xF033 | (_reg(b) << 8))
            elif a == "[I]":
                emit(0xF055 | (_reg(b) << 8))
            else:
                x = _reg(a)
                if b == "DT":
                    emit(0xF007 | (x << 8))
                elif b == "K":
                    emit(0xF00A | (x << 8))
                elif b == "[I]":
                    emit(0xF065 | (x << 8))
                elif _reg(b) is not None:
                    emit(0x8000 | (x << 8) | (_reg(b) << 4))
                else:
                    emit(0x6000 | (x << 8) | (_num(ops[1], labels) & 0xFF))
        elif mnem == "ADD":
            if up[0] == "I":
                emit(0xF01E | (_reg(ops[1]) << 8))
            else:
                x = _reg(ops[0])
                y = _reg(ops[1])
                if y is None:
                    emit(0x7000 | (x << 8) | (_num(ops[1], labels) & 0xFF))
                else:
                    emit(0x8004 | (x << 8) | (y << 4))
        elif mnem in ("OR", "AND", "XOR", "SUB", "SUBN"):
            sub = {"OR": 1, "AND": 2, "XOR": 3, "SUB": 5, "SUBN": 7}[mnem]
            emit(0x8000 | (_reg(ops[0]) << 8) | (_reg(ops[1]) << 4) | sub)
        elif mnem == "SHR":
            y = _reg(ops[1]) if len(ops) > 1 else 0
            emit(0x8006 | (_reg(ops[0]) << 8) | (y << 4))
        elif mnem == "SHL":
            y = _reg(ops[1]) if len(ops) > 1 else 0
            emit(0x800E | (_reg(ops[0]) << 8) | (y << 4))
        elif mnem == "RND":
            emit(0xC000 | (_reg(ops[0]) << 8) | (_num(ops[1], labels) & 0xFF))
        elif mnem == "DRW":
            emit(0xD000 | (_reg(ops[0]) << 8) | (_reg(ops[1]) << 4) | (_num(ops[2], labels) & 0xF))
        elif mnem == "SKP":
            emit(0xE09E | (_reg(ops[0]) << 8))
        elif mnem == "SKNP":
            emit(0xE0A1 | (_reg(ops[0]) << 8))
        else:
            raise ValueError("unknown mnemonic: " + text)
    return bytes(out)


# ---------------------------------------------------------------------------
# Helpers for independent cross-checks
# ---------------------------------------------------------------------------

def blank_display():
    return [[0] * 64 for _ in range(32)]


def draw(disp, x, y, sprite):
    """Independent sprite draw with wrap-around; returns collision flag."""
    hit = 0
    for r, b in enumerate(sprite):
        for c in range(8):
            if (b >> (7 - c)) & 1:
                py = (y + r) & 31
                px = (x + c) & 63
                if disp[py][px]:
                    hit = 1
                disp[py][px] ^= 1
    return hit


def display_of(result):
    disp = result[0]
    return [[(row >> (63 - c)) & 1 for c in range(64)] for row in disp]


def font_glyph(d):
    return list(ref.FONT[d * 5:d * 5 + 5])


def lcg_bytes(n):
    s = ref.LCG_SEED
    out = []
    for _ in range(n):
        s = (s * 1103515245 + 12345) & 0xFFFFFFFF
        out.append((s >> 16) & 0xFF)
    return out


def ticks_between(set_cycle, n_cycles):
    """Number of timer ticks after an FX15 executed in cycle set_cycle."""
    return sum(1 for t in range(set_cycle, n_cycles) if (t + 1) % 8 == 0)


# ---------------------------------------------------------------------------
# Test programs
# ---------------------------------------------------------------------------

def letters_sprites():
    """Striped 'IBM'-style letters, each 16x15, as (left, right) sprites."""
    art = {
        "I": [
            "################",
            "################",
            "################",
            "################",
            "................",
            "....########....",
            "....########....",
            "....########....",
            "....########....",
            "....########....",
            "................",
            "################",
            "################",
            "################",
            "################",
        ],
        "B": [
            "##############..",
            "##############..",
            "####........####",
            "####........####",
            "####........####",
            "##############..",
            "##############..",
            "####........####",
            "####........####",
            "####........####",
            "####........####",
            "####........####",
            "##############..",
            "##############..",
            "##############..",
        ],
        "M": [
            "#####......#####",
            "######....######",
            "#######..#######",
            "################",
            "####.######.####",
            "####..####..####",
            "####...##...####",
            "####...##...####",
            "####........####",
            "####........####",
            "####........####",
            "####........####",
            "####........####",
            "####........####",
            "####........####",
        ],
    }
    out = {}
    for name, rows in art.items():
        left = []
        right = []
        for i, row in enumerate(rows):
            # Every third row is left blank to give the letters horizontal stripes.
            if i % 3 == 2:
                row = "." * 16
            left.append(int(row[:8].replace("#", "1").replace(".", "0"), 2))
            right.append(int(row[8:].replace("#", "1").replace(".", "0"), 2))
        out[name] = (left, right)
    return out


def prog_ibm_logo():
    sp = letters_sprites()
    src = ["CLS", "LD V1, 8"]
    x = 8
    data = []
    for name in "IBM":
        for half, label in zip(sp[name], (name + "L", name + "R")):
            src.append("LD V0, %d" % x)
            src.append("LD I, %s" % label)
            src.append("DRW V0, V1, 15")
            data.append((label, half))
            x += 8
        x += 4
    src.append("halt: JP halt")
    for label, bytes_ in data:
        src.append("%s: DB %s" % (label, ", ".join(str(b) for b in bytes_)))
    rom = assemble("\n".join(src))

    def check(result):
        disp = blank_display()
        x = 8
        for name in "IBM":
            for half in sp[name]:
                draw(disp, x, 8, half)
                x += 8
            x += 4
        assert display_of(result) == disp
    return rom, 40, [], check


def prog_alu():
    """Every 8XYN operation, including X == Y == F corner cases."""
    src = """
        LD V1, 0xC3
        LD V2, 0x5A
        LD V3, V1
        OR V3, V2         ; V3 = 0xDB
        LD V4, V1
        AND V4, V2        ; V4 = 0x42
        LD V5, V1
        XOR V5, V2        ; V5 = 0x99
        LD V6, V1
        ADD V6, V2        ; V6 = 0x1D, VF = 1
        LD V7, VF
        LD V8, V2
        ADD V8, V4        ; V8 = 0x9C, VF = 0
        LD V9, VF
        LD VA, V2
        SUB VA, V1        ; V[A] = 0x97, VF = 0 (borrow)
        LD VB, VF
        LD VC, V1
        SUBN VC, V2       ; V[C] = V2 - V1 = 0x97, VF = 0
        LD VD, VF
        LD VE, V1
        SUB VE, V2        ; V[E] = 0x69, VF = 1
        LD V0, VF
        LD VF, V2
        SHR VF            ; VF = old & 1 = 0 (flag wins)
        ADD V0, VF
        LD VF, V1
        SHL VF            ; VF = (0xC3 >> 7) = 1 (flag wins)
        ADD V0, VF        ; V0 = 2
        LD VF, V1
        ADD VF, V2        ; VF = carry = 1 (flag wins over 0x1D)
        ADD V0, VF        ; V0 = 3
        LD VF, V2
        SUB VF, V1        ; VF = 0 (borrow flag, not 0x97)
        ADD V0, VF        ; V0 = 3
        LD V2, 0x81
        SHR V2            ; V2 = 0x40, VF = 1
        LD V3, VF
        SHL V2            ; V2 = 0x80, VF = 0
        LD V4, VF
        SHL V2            ; V2 = 0x00, VF = 1
        LD V5, VF
        LD V6, 0x77
        SUB V6, V6        ; V6 = 0, VF = 1 (no borrow on equality)
        LD V7, VF
        LD V8, 0x10
        SUBN V8, V8       ; V8 = 0, VF = 1
        LD V9, VF
        LD VA, 0x10
        ADD VA, 0xF5      ; V[A] = 0x05, VF untouched (still 1)
        LD VB, VF
        LD VC, 0xFF
        ADD VC, VC        ; V[C] = 0xFE, VF = 1
        LD VD, 0x00
        ADD VD, 0x00      ; V[D] = 0
        LD VE, 0x01
        LD VF, 0x00
        ADD VE, 0xFF      ; V[E] = 0
    """
    rom = assemble(src)
    expected = [3, 0xC3, 0x00, 1, 0, 1, 0, 1, 0, 1, 0x05, 1, 0xFE, 0, 0, 0]

    def check(result):
        assert result[6] == expected, result[6]
    return rom, len(rom) // 2, [], check


def prog_skips():
    src = """
        LD V0, 0x10
        LD V1, 0x10
        LD V2, 0x11
        SE V0, 0x10       ; skip
        ADD V3, 1
        SE V0, 0x11       ; no skip
        ADD V4, 1
        SNE V0, 0x10      ; no skip
        ADD V5, 1
        SNE V0, 0x11      ; skip
        ADD V6, 1
        SE V0, V1         ; skip
        ADD V7, 1
        SE V0, V2         ; no skip
        ADD V8, 1
        SNE V0, V1        ; no skip
        ADD V9, 1
        SNE V0, V2        ; skip
        ADD VA, 1
        SE V0, 0x10       ; skip over a jump
        JP 0x000
        ADD VB, 1
        DW 0x5011         ; undefined 5XY1: no-op, never skips
        ADD VC, 1
        DW 0x9013         ; undefined 9XY3: no-op
        ADD VD, 1
    """
    rom = assemble(src)
    expected = [0x10, 0x10, 0x11, 0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 1, 0, 0]

    def check(result):
        assert result[6] == expected, result[6]
        assert result[1] == 0x200 + len(rom)
    return rom, 21, [], check


def prog_subroutines():
    src = """
        LD V0, 1
        CALL a
        ADD V0, 0x10      ; after return: V0 = 0x13 + 0x10 = 0x23
        CALL c
        JP done
    a:  ADD V0, 2
        CALL b
        ADD V0, 8
        RET
    b:  ADD V0, 4
        CALL c
        ADD V0, 4
        RET
    c:  ADD V1, 1
        RET
    done:
        LD V2, 0xAA
    halt: JP halt
    """
    rom = assemble(src)

    def check(result):
        V = result[6]
        assert V[0] == 0x23 and V[1] == 2 and V[2] == 0xAA, V
        assert result[3] == 0 and result[1] == 0x200 + len(rom) - 2
    return rom, 200, [], check


def prog_subroutines_midway():
    """Same program, halted while three calls are still on the stack."""
    rom, _, _, _ = prog_subroutines()

    def check(result):
        # Cycles: LD, CALL a, ADD, CALL b, ADD, CALL c -> after 6 cycles SP=3.
        assert result[3] == 3, result[3]
    return rom, 6, [], check


def prog_jump_table():
    src = """
        LD V0, 12
        JP V0, table       ; lands on the fourth 4-byte entry
    table:
        LD V1, 1
        JP halt
        LD V1, 2
        JP halt
        LD V1, 3
        JP halt
        LD V1, 4
    halt: JP halt
    """
    rom = assemble(src)

    def check(result):
        assert result[6][1] == 4
    return rom, 20, [], check


def prog_random():
    """Exercise CXNN with several masks and compare with the LCG directly."""
    src = ["LD I, 0x300"]
    masks = [0xFF, 0x0F, 0xF0, 0x00, 0x01, 0x7E, 0xFF, 0x3F]
    for i, m in enumerate(masks):
        src.append("RND V%X, %d" % (i, m))
    src.append("LD [I], V7")
    src.append("halt: JP halt")
    rom = assemble("\n".join(src))
    rb = lcg_bytes(len(masks))

    def check(result):
        V = result[6]
        for i, m in enumerate(masks):
            assert V[i] == (rb[i] & m), (i, V[i], rb[i], m)
    return rom, 12, [], check


def prog_draw_wrap():
    src = """
        LD V0, 0
        LD V1, 0
        LD V2, 60
        LD V3, 30
        LD V4, 0x7A        ; mod 64 = 58
        LD V5, 0x5F        ; mod 32 = 31
        LD V6, 64          ; wraps to column 0
        LD V7, 32          ; wraps to row 0
        LD I, spr
        DRW V0, V1, 3
        DRW V2, V3, 3      ; wraps both edges
        DRW V4, V5, 3
        DRW V6, V7, 3      ; overlaps the first draw exactly: erases it, VF = 1
        LD V8, VF
        DRW V0, V1, 0      ; N = 0 draws nothing, VF = 0
        LD V9, VF
        LD I, 0xFFF
        DRW V0, V3, 2      ; sprite rows read from 0xFFF and (wrapped) 0x000
    halt: JP halt
    spr: DB 0xFF, 0x81, 0xFF
    """
    rom = assemble(src)

    def check(result):
        disp = blank_display()
        s = [0xFF, 0x81, 0xFF]
        draw(disp, 0, 0, s)
        draw(disp, 60, 30, s)
        draw(disp, 58, 31, s)
        draw(disp, 0, 0, s)
        draw(disp, 0, 30, [0, 0])
        assert display_of(result) == disp
        V = result[6]
        assert V[8] == 1 and V[9] == 0 and V[0xF] == 0
    return rom, 40, [], check


def prog_font_and_bcd():
    """Compute a value, split it with FX33 and draw its digits with FX29."""
    src = """
        LD V0, 0
        LD V1, 0
        LD V2, 200
    loop:
        ADD V1, 3
        ADD V0, V1
        ADD V2, 0xFF
        SNE V2, 0
        JP show
        JP loop
    show:
        LD I, 0x300
        LD B, V0
        LD V3, [I]         ; V0..V3 = hundreds, tens, ones, 0
        LD V4, 10
        LD V5, 5
        LD F, V0
        DRW V4, V5, 5
        ADD V4, 6
        LD F, V1
        DRW V4, V5, 5
        ADD V4, 6
        LD F, V2
        DRW V4, V5, 5
        LD V6, 0xF7        ; FX29 uses the low nibble: glyph 7
        LD F, V6
        LD V4, 40
        DRW V4, V5, 5
    halt: JP halt
    """
    rom = assemble(src)
    v0 = 0
    v1 = 0
    for _ in range(200):
        v1 = (v1 + 3) & 0xFF
        v0 = (v0 + v1) & 0xFF
    digits = [v0 // 100, (v0 // 10) % 10, v0 % 10]

    def check(result):
        V = result[6]
        assert V[0:3] == digits, (V[0:3], digits)
        disp = blank_display()
        for i, d in enumerate(digits):
            draw(disp, 10 + 6 * i, 5, font_glyph(d))
        draw(disp, 40, 5, font_glyph(7))
        assert display_of(result) == disp
    return rom, 2000, [], check


def prog_timers():
    src = """
        LD V0, 0x21
        LD V1, 0x10
        LD DT, V0          ; cycle 2
        LD ST, V1          ; cycle 3
        LD V4, VF
    loop:
        LD V2, DT
        ADD V3, 1          ; counts loop iterations
        SE V2, 0
        JP loop
        LD V5, DT
        LD V6, 0x05
        LD DT, V6
        LD ST, V6
    halt: JP halt
    """
    rom = assemble(src)
    cycles = 100

    def check(result):
        dt = result[4]
        st = result[5]
        assert dt == max(0, 0x21 - ticks_between(2, cycles)), dt
        assert st == max(0, 0x10 - ticks_between(3, cycles)), st
        # The 4-cycle poll loop starts at cycle 5: 23 full iterations plus the
        # LD/ADD/SE of the 24th fit into the remaining 95 cycles.
        assert result[6][3] == 24, result[6][3]
        assert 0x20A <= result[1] < 0x212
    return rom, cycles, [], check


def prog_timers_expire():
    rom, _, _, _ = prog_timers()
    cycles = 400

    def check(result):
        # DT = 0x21 reaches zero after 33 ticks (cycle 263); the loop exits on
        # the next read, the program sets DT = ST = 5, then they tick down.
        assert result[4] < 5 and result[5] < 5
        assert result[6][2] == 0 and result[6][5] == 0
    return rom, cycles, [], check


def prog_keys_wait():
    """FX0A records pressed keys into memory, then draws them as glyphs."""
    src = """
        LD I, 0x400
        LD V1, 1
        LD V5, 8           ; number of keys to collect
    loop:
        LD V0, K
        LD [I], V0
        ADD I, V1
        ADD V2, 1
        SE V2, 8
        JP loop
        LD I, 0x400
        LD V7, [I]         ; V0..V7 = the eight recorded keys
        LD I, 0x400
        LD V8, 2
        LD V9, 3
        LD VA, 0
    draw:
        LD I, 0x400
        ADD I, VA
        LD V0, [I]
        LD F, V0           ; I now points at the glyph, hence the reload above
        DRW V8, V9, 5
        ADD V8, 7
        ADD VA, 1
        SE VA, 8
        JP draw
        LD I, 0x400
        LD V7, [I]
    halt: JP halt
    """
    rom = assemble(src)
    # The wait instruction fires whenever any key is down and the loop takes
    # exactly 6 cycles, so each key is held for exactly 6 cycles: the wait
    # catches it within 5 cycles and has moved on before the release. Two
    # events press several keys at once to exercise the lowest-index rule.
    keys = [0xA, 0x1, 0xF, 0x0, 0x7, 0xC, 0x3, 0x9]
    events = []
    c = 5
    for i, k in enumerate(keys):
        mask = 1 << k
        if i == 2:
            mask |= 1 << 0xC | 1 << 0xB  # lowest pressed key is 0xB
        if i == 4:
            mask |= 1 << 0xE
        events.append((c, mask))
        c += 6
        events.append((c, 0))
        c += 10
    expected_keys = []
    for i, k in enumerate(keys):
        m = events[2 * i][1]
        expected_keys.append(min(j for j in range(16) if (m >> j) & 1))
    cycles = 400

    def check(result):
        V = result[6]
        assert V[0:8] == expected_keys, (V[0:8], expected_keys)
        disp = blank_display()
        for i, k in enumerate(expected_keys):
            draw(disp, (2 + 7 * i) & 0xFF, 3, font_glyph(k))
        assert display_of(result) == disp
    return rom, cycles, events, check


def prog_keys_poll():
    """EX9E / EXA1 polling loops driven by a schedule of key events."""
    src = """
        LD V0, 5
    wait_down:
        ADD V1, 1
        SKP V0
        JP wait_down       ; loops until key 5 is pressed
        LD V2, V1
    wait_up:
        ADD V3, 1
        SKNP V0
        JP wait_up         ; loops until key 5 is released
        LD V4, 0x15        ; key index uses the low nibble: key 5 again
        SKP V4
        LD V5, 1           ; executed only if key 5 is up (it is)
        LD V6, 0x0E
        SKNP V6
        LD V7, 1           ; executed only if key E is down
        SKP V6
        LD V8, 1           ; executed only if key E is up
    halt: JP halt
    """
    rom = assemble(src)
    events = [(31, 0x0020), (34, 0x0020 | 0x4000), (60, 0x4000)]
    cycles = 120

    def check(result):
        V = result[6]
        # Cycle 0 loads V0; the poll loop starts at cycle 1 with 3 cycles per
        # iteration; the SKP at cycle 32 sees the press from cycle 31.
        assert V[2] == 11, V[2]
        assert V[5] == 1 and V[7] == 1 and V[8] == 0, V
    return rom, cycles, events, check


def prog_key_wait_forever():
    """FX0A with no key ever pressed spins for the entire budget; timers tick."""
    src = """
        LD V0, 0x40
        LD DT, V0
        LD V1, K
        LD V2, 0xEE
    """
    rom = assemble(src)
    cycles = 100

    def check(result):
        assert result[1] == 0x204 and result[6][2] == 0
        assert result[4] == 0x40 - ticks_between(1, cycles)
    return rom, cycles, [], check


def prog_memory_ops():
    """FX55/FX65/FX33/FX1E with address wrapping and I left unchanged."""
    src = """
        LD V0, 0x11
        LD V1, 0x22
        LD V2, 0x33
        LD V3, 0x44
        LD I, 0xFFE
        LD [I], V3         ; writes 0xFFE, 0xFFF, 0x000, 0x001
        LD V4, 0xFF
        ADD I, V4          ; I = 0x10FD
        ADD I, V4          ; I = 0x11FC
        LD V5, 0x08
        ADD I, V5          ; I = 0x1204 -> masked 0x204 when accessed
        LD V6, [I]         ; V0..V6 = bytes of the ROM at 0x204..0x20A
        LD VE, V4          ; keep rom[8] before later loads clobber V4
        LD I, 0x000
        LD VA, [I]         ; V0..V[A] from 0x000: 33 44 00 ...
        LD VB, 0xFE
        LD I, 0xFFF
        LD B, VB           ; 2,5,4 at 0xFFF, 0x000, 0x001
        LD I, 0xFFE
        LD V3, [I]         ; V0..V3 = 11 02 05 04
        LD I, 0x9FF
        LD VC, 0xFF
        ADD I, VC
        ADD I, VC
        ADD I, VC
        ADD I, VC          ; I = 0xDFB
        LD VD, 0x01
        LD I, 0x9FF
        ADD I, VD          ; I = 0xA00
    halt: JP halt
    """
    rom = assemble(src)

    def check(result):
        V = result[6]
        assert V[0:4] == [0x11, 2, 5, 4], V
        assert V[0xE] == rom[8], V
        assert V[4:0xB] == [0] * 7 and V[0xB] == 0xFE and V[0xD] == 1, V
        assert result[2] == 0xA00
    return rom, len(rom) // 2 + 5, [], check


def prog_i_high_bits():
    """I climbs past 0xFFF and is reported in full 16 bits."""
    src = """
        LD V0, 0xFF
        LD I, 0xFFF
        ADD I, V0
        ADD I, V0
        ADD I, V0
        LD V1, 0x80
        ADD I, V1          ; I = 0x1000 + 0x2FD - ... computed below
        LD VF, 0x55
        ADD I, VF
    halt: JP halt
    """
    rom = assemble(src)

    def check(result):
        assert result[2] == (0xFFF + 3 * 0xFF + 0x80 + 0x55) & 0xFFFF
        assert result[6][0xF] == 0x55
    return rom, 30, [], check


def prog_undefined_opcodes():
    """Undefined opcodes are two-byte no-ops."""
    src = """
        ADD V0, 1
        DW 0x0123          ; 0NNN: ignored
        ADD V0, 1
        DW 0x5AB1
        ADD V0, 1
        DW 0x8AB8
        ADD V0, 1
        DW 0x8ABF
        ADD V0, 1
        DW 0x9AB3
        ADD V0, 1
        DW 0xE000
        ADD V0, 1
        DW 0xEAFF
        ADD V0, 1
        DW 0xF0FF
        ADD V0, 1
        DW 0xFA00
        ADD V0, 1
        DW 0x0000
        ADD V0, 1
        DW 0x00E1
        ADD V0, 1
        DW 0x00FF
        ADD V0, 1
        DW 0x8AB9
        ADD V0, 1
    """
    rom = assemble(src)

    def check(result):
        assert result[6][0] == 14, result[6]
        assert result[6][0xA] == 0 and result[6][0xF] == 0
        assert result[1] == 0x200 + len(rom)
    return rom, len(rom) // 2, [], check


def prog_pc_wrap():
    """Execution runs off the end of memory, wraps to 0x000 and walks through
    the low memory and the font bytes as instructions."""
    src = """
        LD V0, 0x71        ; instruction bytes to plant at 0xFFE: 71 05 = ADD V1, 5
        LD V1, 0x05
        LD V2, 0x62        ; and at 0x000: 62 9A = LD V2, 0x9A
        LD V3, 0x9A
        LD I, 0xFFE
        LD [I], V3
        LD V1, 0
        JP 0xFFE
    """
    rom = assemble(src)
    # The font bytes decode to 9090 (SNE V0, V9), 6020, 2070 (CALL 0x070)
    # and 1020 (JP 0x020), a loop that pushes one stack entry roughly every
    # 31 cycles; the budget keeps SP well below 16.
    def check(result):
        assert result[3] == 8, result[3]
    return rom, 280, [], check


def prog_recursion():
    """Recursive routine 15 levels deep, halted with a partially unwound stack."""
    src = """
        LD V0, 0
        LD V1, 0
        CALL rec
        LD V3, 0xEE
    halt: JP halt
    rec:
        ADD V0, 1
        SE V0, 15
        CALL rec
        ADD V1, V0         ; sums 15+14+...+1 = 120 on the way back up
        ADD V0, 0xFF
        RET
    """
    rom = assemble(src)

    def check_full(result):
        V = result[6]
        assert V[0] == 0 and V[1] == 120 and V[3] == 0xEE and result[3] == 0
    # Descent: cycles 0,1 setup; cycle 2 CALL; each level = ADD, SE, CALL
    # (3 cycles). The CALL in cycle 2 + 3*10 = 32 pushes the 11th entry, so
    # after 33 cycles SP = 11 and V0 = 10.
    def check_mid(result):
        assert result[3] == 11, result[3]
        assert result[6][0] == 10
    return (rom, 300, [], check_full), (rom, 33, [], check_mid)


def prog_sieve():
    """Sieve of Eratosthenes over 0..255 in memory, then plot primes as pixels."""
    src = """
        LD I, dot
        LD V1, 1
        LD V2, 2           ; i
    outer:
        LD I, 0x600
        ADD I, V2
        LD V0, [I]
        SNE V0, 0
        JP mark
    next_i:
        ADD V2, 1
        SE V2, 16
        JP outer
        JP plot
    mark:
        LD V3, V2
        LD V4, V2
        ADD V3, V4         ; j = 2 * i
    inner:
        LD I, 0x600
        ADD I, V3
        LD V0, V1
        LD [I], V0         ; flag[j] = 1
        ADD V3, V4         ; j += i, VF = 1 on overflow past 255
        SE VF, 1
        JP inner
        JP next_i
    plot:
        LD V5, 2           ; n
    ploop:
        LD I, 0x600
        ADD I, V5
        LD V0, [I]
        SNE V0, 0
        CALL pixel
        ADD V5, 1
        SE V5, 0
        JP ploop
    halt: JP halt
    pixel:
        LD V6, V5
        LD V7, 63
        AND V6, V7         ; x = n & 63
        LD V7, V5
        SHR V7
        SHR V7
        SHR V7
        SHR V7
        SHR V7
        SHR V7             ; y = n >> 6
        LD I, dot
        DRW V6, V7, 1
        RET
    dot: DB 0x80
    """
    rom = assemble(src)
    primes = [n for n in range(2, 256) if all(n % p for p in range(2, int(n ** 0.5) + 1))]

    def check(result):
        disp = blank_display()
        for n in primes:
            disp[n >> 6][n & 63] = 1
        assert display_of(result) == disp
    return rom, 20000, [], check


def prog_rule90():
    """Rule 90 cellular automaton over a 64-cell row, 32 generations, drawn
    one row per generation from a single seed cell: a Sierpinski triangle."""
    CUR = 0x700   # 8 bytes, current generation
    NXT = 0x710   # 8 bytes, next generation
    src = []
    src.append("LD I, seed")
    src.append("LD V7, [I]")
    src.append("LD I, %d" % CUR)
    src.append("LD [I], V7")
    src.append("LD VD, 0")            # generation / row index
    src.append("gen:")
    # Draw the current row as eight 1-byte sprites.
    for k in range(8):
        src.append("LD VC, %d" % (8 * k))
        src.append("LD I, %d" % (CUR + k))
        src.append("DRW VC, VD, 1")
    # Load the row into V1..V8 (V0 receives the byte before the buffer).
    src.append("LD I, %d" % (CUR - 1))
    src.append("LD V8, [I]")
    for k in range(8):
        r = k + 1
        # Left neighbour contribution: row[k] >> 1 with the low bit of row[k-1]
        # entering at bit 7.
        src.append("LD V9, V%X" % r)
        src.append("SHR V9")
        if k > 0:
            src.append("LD VA, V%X" % (r - 1))
            src.append("SHR VA")
            src.append("LD VA, VF")
            for _ in range(7):
                src.append("SHL VA")
            src.append("OR V9, VA")
        # Right neighbour contribution: row[k] << 1 with the high bit of
        # row[k+1] entering at bit 0.
        src.append("LD VA, V%X" % r)
        src.append("SHL VA")
        if k < 7:
            src.append("LD VB, V%X" % (r + 1))
            src.append("SHL VB")
            src.append("OR VA, VF")
        src.append("XOR V9, VA")
        src.append("LD V0, V9")
        src.append("LD I, %d" % (NXT + k))
        src.append("LD [I], V0")
    src.append("LD I, %d" % NXT)
    src.append("LD V7, [I]")
    src.append("LD I, %d" % CUR)
    src.append("LD [I], V7")
    src.append("ADD VD, 1")
    src.append("SE VD, 32")
    src.append("JP gen")
    src.append("halt: JP halt")
    src.append("seed: DB 0, 0, 0, 0, 0x80, 0, 0, 0")
    rom = assemble("\n".join(src))

    def check(result):
        row = [0] * 64
        row[32] = 1
        disp = []
        for _ in range(32):
            disp.append(list(row))
            row = [(row[i - 1] if i > 0 else 0) ^ (row[i + 1] if i < 63 else 0) for i in range(64)]
        assert display_of(result) == disp
    return rom, 12000, [], check


def prog_bouncing_ball(cycles):
    src = """
        LD V0, 20          ; x
        LD V1, 7           ; y
        LD V2, 1           ; dx
        LD V3, 1           ; dy
        LD I, ball
        DRW V0, V1, 5
    frame:
        DRW V0, V1, 5      ; erase
        ADD V0, V2
        ADD V1, V3
        SNE V0, 0
        LD V2, 1
        SNE V0, 56
        LD V2, 0xFF
        SNE V1, 0
        LD V3, 1
        SNE V1, 27
        LD V3, 0xFF
        DRW V0, V1, 5      ; draw
        ADD V4, 1          ; frame counter (mod 256)
        JP frame
    ball: DB 0x38, 0x7C, 0xFE, 0x7C, 0x38
    """
    rom = assemble(src)
    return rom, cycles, [], None


def prog_sprite_storm(cycles):
    """Random glyphs drawn at random positions; VF collisions accumulate."""
    src = """
        LD VE, 1
    loop:
        RND VA, 0x3F
        RND VB, 0x1F
        RND VC, 0x0F
        LD F, VC
        DRW VA, VB, 5
        ADD VD, VF
        ADD V8, 1
        SE V8, 0
        JP loop
        ADD V9, 1          ; V9 counts every 256 draws
        JP loop
    """
    rom = assemble(src)
    return rom, cycles, [], None


def prog_multiply_divide():
    """Shift-and-add multiplication and restoring division, results stored
    via FX55 and shown as BCD digits."""
    src = """
        LD V0, 0
        LD V1, 0
        LD V2, 0x2D        ; a = 45
        LD V3, 0x1F        ; b = 31
        CALL mul
        LD V4, V0          ; 45 * 31 = 1395 = 0x0573: hi 05, lo 73
        LD V5, V1
        LD V2, 0xE9        ; 233
        LD V3, 0x11        ; 17
        CALL div           ; 233 / 17 = 13 rem 12
        LD V6, V0
        LD V7, V1
        LD I, 0x500
        LD [I], V7
        LD I, 0x510
        LD B, V4
        LD V8, 3
        LD V9, 20
        LD VA, 0
    show:
        LD I, 0x510
        ADD I, VA
        LD V0, [I]
        LD F, V0
        DRW V8, V9, 5
        ADD V8, 6
        ADD VA, 1
        SE VA, 3
        JP show
    halt: JP halt
    mul:                   ; (V1:V0) = V2 * V3, 16-bit result
        LD V0, 0
        LD V1, 0
        LD V6, V2          ; multiplicand low
        LD V7, 0           ; multiplicand high
        LD V8, V3          ; multiplier
    mloop:
        SE V8, 0
        JP mstep
        RET
    mstep:
        SHR V8
        SE VF, 1
        JP mskip
        ADD V0, V6
        ADD V1, VF
        ADD V1, V7
    mskip:
        SHL V6
        LD V9, VF          ; carry out of the low byte
        SHL V7
        OR V7, V9
        JP mloop
    div:                   ; V0 = V2 / V3, V1 = V2 % V3 (repeated subtraction)
        LD V0, 0
        LD V1, V2
    dloop:
        LD V9, V1
        SUB V9, V3
        SE VF, 1
        RET
        LD V1, V9
        ADD V0, 1
        JP dloop
    """
    rom = assemble(src)

    def check(result):
        V = result[6]
        assert V[4] == 0x73 and V[5] == 0x05 and V[6] == 13 and V[7] == 12, V
        disp = blank_display()
        for i, d in enumerate([1, 1, 5]):
            draw(disp, 3 + 6 * i, 20, font_glyph(d))
        assert display_of(result) == disp
    return rom, 1500, [], check


def prog_alu_loop(cycles):
    """Tight arithmetic loop for throughput testing; every result feeds the next."""
    src = """
        LD V0, 0x01
        LD V1, 0x9E
        LD V2, 0x37
        LD V3, 0xC5
    loop:
        ADD V0, V1
        XOR V1, V2
        SHL V2
        OR V2, VF
        SUB V3, V0
        ADD V3, VF
        SHR V1
        SUBN V2, V1
        ADD V4, 1
        ADD V5, VF
        AND V1, V3
        ADD V1, 0x5B
        JP loop
    """
    rom = assemble(src)
    return rom, cycles, [], None


# ---------------------------------------------------------------------------
# Random instruction soups
# ---------------------------------------------------------------------------

def random_soup(rng, n_instr, cycles, n_events):
    """Random 2-byte instructions with jumps aimed inside the program.

    Calls and returns are never emitted directly; a seed whose execution still
    reaches a call/return through misaligned fetches and overflows or empties
    the stack is rejected by the caller.
    """
    end = 0x200 + 2 * n_instr
    words = []
    for _ in range(n_instr):
        r = rng.random()
        if r < 0.05:
            w = 0x1000 | rng.randrange(0x200, end, 2)
        elif r < 0.07:
            w = 0xB000 | rng.randrange(0x200, end, 2)
        elif r < 0.30:
            w = (0x6000 if rng.random() < 0.5 else 0x7000) | rng.randrange(0x1000)
        elif r < 0.55:
            w = 0x8000 | (rng.randrange(16) << 8) | (rng.randrange(16) << 4) | rng.choice([0, 1, 2, 3, 4, 5, 6, 7, 0xE, 0xE, 0x6])
        elif r < 0.62:
            w = rng.choice([0x3000, 0x4000, 0x5000, 0x9000]) | rng.randrange(0x1000)
        elif r < 0.68:
            w = 0xA000 | rng.randrange(0x1000)
        elif r < 0.73:
            w = 0xC000 | rng.randrange(0x1000)
        elif r < 0.88:
            w = 0xD000 | rng.randrange(0x1000)
        elif r < 0.92:
            w = 0xE000 | (rng.randrange(16) << 8) | rng.choice([0x9E, 0xA1])
        elif r < 0.99:
            w = 0xF000 | (rng.randrange(16) << 8) | rng.choice([0x07, 0x0A, 0x15, 0x18, 0x1E, 0x29, 0x33, 0x55, 0x65])
        else:
            w = rng.choice([0x00E0, 0x0123, 0x8AB8, 0xF0FF])
        words.append(w)
    rom = bytearray()
    for w in words:
        rom += bytes([w >> 8, w & 0xFF])
    events = []
    c = 0
    for _ in range(n_events):
        c += rng.randrange(1, max(2, cycles // (n_events + 1)))
        if c > cycles:
            break
        events.append((c, rng.randrange(0x10000) if rng.random() < 0.7 else 0))
    return bytes(rom), events


def make_soup(seed, n_instr, cycles, n_events):
    rng = random.Random(seed)
    while True:
        rom, events = random_soup(rng, n_instr, cycles, n_events)
        try:
            full = ref.run(rom, cycles, events)
            part = ref.run(rom, cycles * 3 // 4, events)
        except ref.StackFault:
            continue
        # Reject programs that have settled into a loop that changes nothing
        # observable during the last quarter of the budget.
        if (full[0], full[2], full[6]) == (part[0], part[2], part[6]):
            continue
        if not any(full[0]):
            continue
        return rom, cycles, events, None


def prog_bnnn_wrap():
    """BNNN whose target exceeds 0xFFF wraps into low memory, where a planted
    instruction proves execution really landed at 0x008."""
    src = """
        LD V0, 0x10
        LD V1, 0x63        ; bytes planted at 0x007..0x009: 10 63 42, so 0x008 holds LD V3, 0x42
        LD V2, 0x42
        LD I, 0x007
        LD [I], V2
        JP V0, 0xFF8       ; PC = (0xFF8 + 0x10) & 0xFFF = 0x008
    """
    rom = assemble(src)

    def check(result):
        assert result[1] == 0x00A and result[6][3] == 0x42 and result[3] == 0, result[1:4]
    return rom, 7, [], check


def prog_key_high_bits():
    """EX9E/EXA1 test key VX & 0xF, so V0 = 0x1A refers to key A."""
    src = """
        LD V0, 0x1A
        SKP V0             ; key A is down: skip
        LD V1, 0xEE
        LD V2, 0xFA
        SKNP V2            ; key A is down: no skip
        LD V3, 0x33
        LD V4, 0x2B
        SKP V4             ; key B is up: no skip
        LD V5, 0x55
        SKNP V4            ; key B is up: skip
        LD V6, 0x66
    halt: JP halt
    """
    rom = assemble(src)

    def check(result):
        V = result[6]
        assert (V[1], V[3], V[5], V[6]) == (0, 0x33, 0x55, 0), V
    return rom, 20, [(0, 0x0400)], check


def prog_pc_fff_fetch():
    """A full 3584-byte ROM puts 0x61 at 0xFFF; jumping there fetches the
    opcode 61xx whose low byte comes from address 0x000 (planted as 0x37),
    then execution continues from the odd address 0x001."""
    src = """
        LD V0, 0x37
        LD I, 0x000
        LD [I], V0         ; mem[0x000] = 0x37
        JP 0xFFF
    """
    rom = bytearray(assemble(src))
    rom += bytes(3584 - len(rom))
    rom[-1] = 0x61
    assert len(rom) == 3584

    def check(result):
        # Cycle 4 executes 0x6137 (LD V1, 0x37) and leaves PC = 0x001; cycles
        # 5-7 execute three 0000 no-ops from 0x001, 0x003 and 0x005.
        assert result[1] == 0x007 and result[6][1] == 0x37 and result[2] == 0, result[1:3]
    return bytes(rom), 8, [], check


def prog_random_vf():
    """CXNN leaves VF alone unless X = F, and NN = 0 still advances the RNG."""
    src = """
        LD VF, 1
        RND V0, 0xFF
        LD V1, VF          ; still 1
        RND VF, 0x0F
        RND V2, 0x00       ; consumes a random byte, V2 = 0
        RND V3, 0xFF
    """
    rom = assemble(src)

    def check(result):
        V = result[6]
        b = lcg_bytes(4)
        assert (V[0], V[1], V[0xF], V[2], V[3]) == (b[0], 1, b[1] & 0x0F, 0, b[3]), V
    return rom, 6, [], check


def prog_stack_full():
    """Sixteen nested calls fill the stack (SP = 16); running on, sixteen
    returns unwind it completely. Returns (full, unwound) tests."""
    words = []
    for k in range(16):
        words.append(0x2000 | (0x204 + 4 * k))   # at 0x200 + 4k: CALL next
        words.append(0x00EE if k > 0 else 0x1202)  # at 0x202 + 4k: RET (k=0: JP self)
    words.append(0x00EE)                         # at 0x240
    rom = bytes(b for w in words for b in (w >> 8, w & 0xFF))

    def check_full(result):
        assert result[3] == 16 and result[1] == 0x240, result[1:4]

    def check_unwound(result):
        assert result[3] == 0 and result[1] == 0x202, result[1:4]
    return (rom, 16, [], check_full), (rom, 40, [], check_unwound)


def prog_all_regs_memory():
    """FF55/FF65 store and load all sixteen registers, VF included."""
    src = "\n".join("LD V%X, 0x%02X" % (k, 0x10 + k) for k in range(16))
    src += "\nLD I, 0x300\nLD [I], VF\n"
    src += "\n".join("LD V%X, 0x%02X" % (k, 0xA0 + k) for k in range(16))
    src += "\nLD I, 0x300\nLD VF, [I]\nhalt: JP halt\n"
    rom = assemble(src)

    def check(result):
        assert result[6] == [0x10 + k for k in range(16)] and result[2] == 0x300, result[6]
    return rom, 40, [], check


def prog_i_wrap_16bit():
    """FX1E is masked to 16 bits: I climbs from 0xFFF by 241 * 0xFF and wraps
    to 0x000E. Before that a draw with I = 0x1050 reads the glyph '0' through
    the 12-bit address mask."""
    src = """
        LD I, 0xFFF
        LD V2, 0x51
        ADD I, V2          ; I = 0x1050
        DRW V3, V4, 5      ; glyph 0 at (0, 0)
        LD I, 0xFFF
        LD V0, 0xFF
        LD V1, 241
    loop:
        ADD I, V0
        ADD V1, 0xFF
        SE V1, 0
        JP loop
    halt: JP halt
    """
    rom = assemble(src)

    def check(result):
        assert result[2] == (0xFFF + 241 * 0xFF) & 0xFFFF == 0x000E, hex(result[2])
        disp = display_of(result)
        want = blank_display()
        draw(want, 0, 0, font_glyph(0))
        assert disp == want and result[6][0xF] == 0
    return rom, 1000, [], check


# ---------------------------------------------------------------------------
# Test list
# ---------------------------------------------------------------------------

def build_tests():
    rec_full, rec_mid = prog_recursion()
    stack_full, stack_unwound = prog_stack_full()
    tests = [
        ("zero_cycles", (bytes([0x00, 0xE0]), 0, [], None)),
        ("cls_only", (bytes([0x00, 0xE0]), 1, [], None)),
        ("spec_example1", (bytes.fromhex("60ff7001610180141208"), 6, [], None)),
        ("spec_example2", (bytes.fromhex("6a3e6b1e6000f029dab5dab5"), 5, [], None)),
        ("spec_example3", (bytes.fromhex("c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a"), 14, [(9, 0x0300)], None)),
        ("load_add_wrap", (assemble("LD V0, 0xFF\nADD V0, 1\nLD V1, 0x80\nADD V1, 0x80\nLD VF, 3\nADD VF, 0xFF\nLD V2, 5"), 7, [],
                           lambda r: (r[6][0] == 0 and r[6][1] == 0 and r[6][0xF] == 2 and r[6][2] == 5) or (_ for _ in ()).throw(AssertionError(r[6])))),
        ("alu_ops", prog_alu()),
        ("skips", prog_skips()),
        ("subroutines", prog_subroutines()),
        ("subroutines_midway", prog_subroutines_midway()),
        ("jump_table", prog_jump_table()),
        ("random_lcg", prog_random()),
        ("draw_wrap_collision", prog_draw_wrap()),
        ("font_bcd", prog_font_and_bcd()),
        ("timers", prog_timers()),
        ("timers_expire", prog_timers_expire()),
        ("keys_wait", prog_keys_wait()),
        ("keys_poll", prog_keys_poll()),
        ("key_wait_forever", prog_key_wait_forever()),
        ("memory_ops", prog_memory_ops()),
        ("i_high_bits", prog_i_high_bits()),
        ("undefined_opcodes", prog_undefined_opcodes()),
        ("pc_wrap", prog_pc_wrap()),
        ("recursion", rec_full),
        ("recursion_midway", rec_mid),
        ("stack_full", stack_full),
        ("stack_unwound", stack_unwound),
        ("bnnn_wrap", prog_bnnn_wrap()),
        ("key_high_bits", prog_key_high_bits()),
        ("pc_fff_fetch", prog_pc_fff_fetch()),
        ("random_vf", prog_random_vf()),
        ("all_regs_memory", prog_all_regs_memory()),
        ("i_wrap_16bit", prog_i_wrap_16bit()),
        ("ibm_logo", prog_ibm_logo()),
        ("multiply_divide", prog_multiply_divide()),
        ("sieve_primes", prog_sieve()),
        ("rule90_sierpinski", prog_rule90()),
        ("bouncing_ball_short", prog_bouncing_ball(3000)),
        ("soup_small_a", make_soup(1, 64, 2000, 3)),
        ("soup_small_b", make_soup(2, 96, 5000, 4)),
        ("soup_medium_a", make_soup(3, 512, 100000, 10)),
        ("soup_medium_b", make_soup(4, 768, 200000, 12)),
        ("soup_large", make_soup(5, 1792, 1000000, 20)),
        ("bouncing_ball_long", prog_bouncing_ball(1000000)),
        ("sprite_storm", prog_sprite_storm(5000000)),
        ("alu_loop_5m", prog_alu_loop(5000000)),
    ]
    return tests


def main():
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        if f.endswith(".in") or f.endswith(".out"):
            os.remove(os.path.join(TESTS, f))
    tests = build_tests()
    for idx, (name, (rom, cycles, events, check)) in enumerate(tests, 1):
        assert 1 <= len(rom) <= 3584, name
        for c, m in events:
            assert 0 <= c <= cycles and 0 <= m <= 0xFFFF
        assert all(events[i][0] < events[i + 1][0] for i in range(len(events) - 1)), name
        text = rom.hex() + "\n" + str(cycles) + "\n"
        if events:
            text += " ".join("%d:%04x" % (c, m) for c, m in events) + "\n"
        result = ref.run(rom, cycles, events)
        if check is not None:
            check(result)
        base = os.path.join(TESTS, "%03d_%s" % (idx, name))
        with open(base + ".in", "w") as f:
            f.write(text)
        with open(base + ".out", "w") as f:
            f.write(ref.format_state(*result))
        print("wrote", os.path.basename(base), "rom=%d cycles=%d" % (len(rom), cycles))


if __name__ == "__main__":
    main()
