#!/usr/bin/env python3
"""Generate the chip8 performance benchmark inputs (bench/*.in, *.out).

Every input runs the maximum cycle budget the spec allows (5,000,000). The
ROMs are assembled with the assembler from ../gen_tests.py and expected
outputs come from the reference implementation. Deterministic: the only
randomness is the seeded instruction soup in the third input.
"""
import argparse
import os
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import gen_tests  # noqa: E402
from gen_tests import assemble, ref  # noqa: E402

CYCLES = 5000000

# Long tier: the same three programs run for many more cycles (SPEC.md allows
# up to 4,000,000,000), sized so the fastest implementation needs >= 5 s.
LONG_CYCLES = {
    "cpu_kernel": 3200000000,
    "sprite_scene": 2000000000,
    "mixed_soup_keys": 2400000000,
}
LONG_SOUP_EVENTS = 200000


def prog_cpu_kernel(cycles=CYCLES):
    """Integer workload: fill a 256-byte buffer with block stores (FX55),
    checksum it with block loads (FX65), dispatch through a BNNN jump table,
    run a repeated-subtraction division in a nested call, and show the
    checksum as three BCD digits. Few draws; dominated by ALU, branch,
    call/return and memory-transfer instructions."""
    src = """
        LD VE, 0
    main:
        LD V8, VE
        LD I, buf
        CALL fill
        LD I, buf
        CALL sum
        CALL dispatch
        CALL divide
        CALL show
        ADD VE, 1
        JP main

    fill:                  ; 32 blocks of 8 bytes derived from seed V8
        LD VD, 32
        LD VC, 8
    floop:
        LD V0, V8
        ADD V0, 0x3B
        LD V1, V0
        SHL V1
        XOR V1, V8
        LD V2, V1
        ADD V2, V0
        LD V3, V2
        SHR V3
        XOR V3, V1
        LD V4, V3
        SUB V4, V0
        LD V5, V4
        OR V5, V2
        LD V6, V5
        AND V6, V3
        LD V7, V6
        SUBN V7, V1
        LD V8, V7
        ADD V8, V4
        LD [I], V7
        ADD I, VC
        ADD VD, 0xFF
        SE VD, 0
        JP floop
        RET

    sum:                   ; V9:VA = 16-bit sum, VB = xor of all bytes
        LD V9, 0
        LD VA, 0
        LD VB, 0
        LD VD, 32
        LD VC, 8
    sloop:
        LD V7, [I]
        ADD VA, V0
        ADD V9, VF
        ADD VA, V1
        ADD V9, VF
        ADD VA, V2
        ADD V9, VF
        ADD VA, V3
        ADD V9, VF
        ADD VA, V4
        ADD V9, VF
        ADD VA, V5
        ADD V9, VF
        ADD VA, V6
        ADD V9, VF
        ADD VA, V7
        ADD V9, VF
        XOR VB, V0
        XOR VB, V3
        XOR VB, V7
        ADD I, VC
        ADD VD, 0xFF
        SE VD, 0
        JP sloop
        RET

    dispatch:              ; jump to handler (VA & 7) through a table
        LD V0, VA
        LD V1, 7
        AND V0, V1
        SHL V0
        JP V0, table
    table:
        JP h0
        JP h1
        JP h2
        JP h3
        JP h4
        JP h5
        JP h6
        JP h7
    h0: ADD VB, 1
        RET
    h1: XOR VB, V9
        RET
    h2: SHL VB
        RET
    h3: SHR VB
        RET
    h4: SUB VB, V9
        RET
    h5: SUBN VB, VA
        RET
    h6: OR VB, VA
        RET
    h7: AND VB, V9
        ADD VB, 0x11
        RET

    divide:                ; V5 = VA / (V9 | 1), V6 = remainder
        LD V3, V9
        LD V4, 1
        OR V3, V4
        LD V5, 0
        LD V6, VA
    dloop:
        LD V4, V6
        SUB V4, V3
        SE VF, 1
        RET
        LD V6, V4
        ADD V5, 1
        JP dloop

    show:                  ; XOR-draw BCD digits of VA at a position from VE
        LD I, digits
        LD B, VA
        LD V2, [I]
        LD V3, VE
        LD V4, 0x1F
        AND V3, V4
        LD V4, 2
        LD F, V0
        DRW V3, V4, 5
        ADD V3, 5
        LD F, V1
        DRW V3, V4, 5
        ADD V3, 5
        LD F, V2
        DRW V3, V4, 5
        RET

    digits: DB 0, 0, 0, 0
    buf: DB 0
    """
    return assemble(src), cycles, []


SPRITES = [
    # 8x15 sprites: ship, asteroid, alien, block
    [0x18, 0x18, 0x3C, 0x3C, 0x7E, 0x7E, 0xFF, 0xFF, 0xDB, 0xDB, 0x99, 0x81, 0x81, 0x42, 0x24],
    [0x3C, 0x7E, 0xFF, 0xF7, 0xE3, 0xFF, 0xDF, 0xFF, 0xFB, 0xF1, 0xFF, 0x7F, 0x7E, 0x3C, 0x18],
    [0x24, 0x24, 0x7E, 0xDB, 0xFF, 0xFF, 0x7E, 0x3C, 0x66, 0xC3, 0x81, 0x42, 0x24, 0x66, 0x00],
    [0xFF, 0x81, 0xBD, 0xA5, 0xA5, 0xBD, 0x81, 0xFF, 0x81, 0xBD, 0xA5, 0xA5, 0xBD, 0x81, 0xFF],
]


def prog_sprite_scene(cycles=CYCLES):
    """Game-style frame loop: clear the screen, then move and draw 24
    objects as 8x15 sprites (each drawn twice, body plus offset shadow, so
    collisions are frequent), keep positions in a memory table via FX65/FX55,
    count collisions, and set the delay timer once per frame. Dominated by
    DXYN with the largest sprite height."""
    sheet = ", ".join("0x%02X" % b for s in SPRITES for b in s)
    init = ", ".join("%d, %d, %d, %d" % ((i * 11) % 64, (i * 7) % 32, (i % 5) + 1, (i % 3) + 1)
                     for i in range(24))
    src = """
    frame:
        CLS
        LD VE, 0
        LD I, objs
    obj:
        LD V3, [I]          ; V0=x V1=y V2=dx V3=dy
        ADD V0, V2
        ADD V1, V3
        LD [I], V3
        LD V8, 4
        ADD I, V8
        LD V9, VE
        LD VA, 3
        AND V9, VA
        LD VA, 15
        LD VB, 0
    mul15:
        SNE V9, 0
        JP drawit
        ADD VB, VA
        ADD V9, 0xFF
        JP mul15
    drawit:
        LD I, sheet
        ADD I, VB
        DRW V0, V1, 15
        ADD VD, VF
        ADD V0, 3
        ADD V1, 2
        DRW V0, V1, 15
        ADD VC, VF
        LD I, objs
        ADD VE, 1
        LD V9, VE
        SHL V9
        SHL V9
        ADD I, V9
        SE VE, 24
        JP obj
        LD V6, 2
        LD DT, V6
        ADD V4, 1
        JP frame
    sheet: DB %s
    objs: DB %s
    """ % (sheet, init)
    return assemble(src), cycles, []


def prog_mixed_soup():
    """A full-size 3584-byte ROM of random instructions (the generator used
    by the public tests' soup cases) with a dense key schedule of 20,000
    events: every opcode class, key polling and waiting, timers, random
    numbers and frequent draws, across a large code footprint."""
    rom, cycles, events, _ = gen_tests.make_soup(2024, 1792, CYCLES, 20000)
    return rom, cycles, events


def prog_mixed_soup_long():
    """The long-tier soup: same generator and seed, a longer run and a key
    schedule of 200,000 events. Acceptance mirrors gen_tests.make_soup (no
    stack fault, visible state still changing in the last quarter), and the
    full run's result is returned so the reference runs only twice."""
    import random
    cycles = LONG_CYCLES["mixed_soup_keys"]
    rng = random.Random(2024)
    while True:
        rom, events = gen_tests.random_soup(rng, 1792, cycles, LONG_SOUP_EVENTS)
        try:
            full = ref.run(rom, cycles, events)
            part = ref.run(rom, cycles * 3 // 4, events)
        except ref.StackFault:
            continue
        if (full[0], full[2], full[6]) == (part[0], part[2], part[6]):
            continue
        if not any(full[0]):
            continue
        return rom, cycles, events, full


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--long", action="store_true",
                    help="write the long tier to ../bench-long instead")
    ap.add_argument("only", nargs="*", help="regenerate only inputs whose name contains one of these")
    args = ap.parse_args()
    if args.long:
        out_dir = os.path.join(os.path.dirname(HERE), "bench-long")
        os.makedirs(out_dir, exist_ok=True)
        benches = [
            ("cpu_kernel_5m", lambda: prog_cpu_kernel(LONG_CYCLES["cpu_kernel"])),
            ("sprite_scene_5m", lambda: prog_sprite_scene(LONG_CYCLES["sprite_scene"])),
            ("mixed_soup_keys_5m", prog_mixed_soup_long),
        ]
        max_cycles = 4000000000
    else:
        out_dir = HERE
        benches = [
            ("cpu_kernel_5m", prog_cpu_kernel),
            ("sprite_scene_5m", prog_sprite_scene),
            ("mixed_soup_keys_5m", prog_mixed_soup),
        ]
        max_cycles = 5000000
    def wanted(name):
        return not args.only or any(o in name for o in args.only)

    for f in os.listdir(out_dir):
        if (f.endswith(".in") or f.endswith(".out")) and wanted(f):
            os.remove(os.path.join(out_dir, f))
    for idx, (name, build) in enumerate(benches, 1):
        if not wanted(name):
            continue
        prog = build()
        rom, cycles, events = prog[:3]
        known = prog[3] if len(prog) > 3 else None
        assert 1 <= len(rom) <= 3584, (name, len(rom))
        assert 0 <= cycles <= max_cycles
        for c, m in events:
            assert 0 <= c <= cycles and 0 <= m <= 0xFFFF
        assert all(events[i][0] < events[i + 1][0] for i in range(len(events) - 1)), name
        text = rom.hex() + "\n" + str(cycles) + "\n"
        if events:
            text += " ".join("%d:%04x" % (c, m) for c, m in events) + "\n"
        result = known if known is not None else ref.run(rom, cycles, events)
        base = os.path.join(out_dir, "%03d_%s" % (idx, name))
        with open(base + ".in", "w") as f:
            f.write(text)
        with open(base + ".out", "w") as f:
            f.write(ref.format_state(*result))
        print("wrote", os.path.basename(base), "rom=%d cycles=%d events=%d" % (len(rom), cycles, len(events)))


if __name__ == "__main__":
    main()
