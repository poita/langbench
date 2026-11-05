module tests.test_machine;

import chip8;
import tests.helpers;

@("reset installs font and PC")
unittest
{
    Machine m;
    m.reset();
    assert(m.pc == 0x200);
    assert(m.mem[0x50] == 0xF0 && m.mem[0x9F] == 0x80);
    assert(m.mem[0x200] == 0);
}

@("zero cycles do nothing")
unittest
{
    auto m = runCode([0x6001], 0);
    assert(m.pc == 0x200 && m.v[0] == 0);
}

@("arithmetic example from the spec")
unittest
{
    auto m = runCode([0x60ff, 0x7001, 0x6101, 0x8014, 0x1208], 6);
    assert(m.pc == 0x208);
    assert(m.v[0] == 1 && m.v[1] == 1 && m.v[15] == 0);
}

@("8XY4 carry and flag wins when X = F")
unittest
{
    auto m = runCode([0x60ff, 0x6102, 0x8014], 3);
    assert(m.v[0] == 1 && m.v[15] == 1);
    m = runCode([0x6fff, 0x6102, 0x8f14], 3);
    assert(m.v[15] == 1);
}

@("8XY5 / 8XY7 borrow flags")
unittest
{
    auto m = runCode([0x6005, 0x6105, 0x8015], 3);
    assert(m.v[0] == 0 && m.v[15] == 1);
    m = runCode([0x6005, 0x6106, 0x8015], 3);
    assert(m.v[0] == 0xff && m.v[15] == 0);
    m = runCode([0x6005, 0x6106, 0x8017], 3);
    assert(m.v[0] == 1 && m.v[15] == 1);
}

@("shifts ignore VY and set the flag")
unittest
{
    auto m = runCode([0x6003, 0x61f0, 0x8016], 3);
    assert(m.v[0] == 1 && m.v[15] == 1);
    m = runCode([0x6081, 0x800e], 2);
    assert(m.v[0] == 2 && m.v[15] == 1);
}

@("skips and odd opcodes")
unittest
{
    auto m = runCode([0x6001, 0x3001, 0x6002, 0x4001, 0x6003, 0x5010, 0x9010], 6);
    // 3001 skips 6002; 4001 does not skip 6003 -> V0 = 3; 5010 (V0 != V1) no skip; 9010 skips
    assert(m.v[0] == 3);
    assert(m.pc == 0x210);
    m = runCode([0x5011, 0x8018, 0x9013, 0xe000, 0xf0ff, 0x0123], 6);
    assert(m.pc == 0x20c);
}

@("call and return, full stack")
unittest
{
    auto m = runCode([0x2204, 0x1202, 0x00ee], 3);
    assert(m.pc == 0x202 && m.sp == 0);
    // sixteen nested calls to the next instruction
    ushort[] code;
    foreach (k; 0 .. 16) code ~= cast(ushort)(0x2000 | (0x202 + 2 * k));
    m = runCode(code, 16);
    assert(m.sp == 16 && m.stack[15] == 0x220);
}

@("BNNN uses V0 and masks")
unittest
{
    auto m = runCode([0x60ff, 0xbf01], 2);
    assert(m.pc == 0x000);
    m = runCode([0x6001, 0xb300], 2);
    assert(m.pc == 0x301);
}

@("PC wraps around at 0xFFF")
unittest
{
    Machine m;
    m.reset();
    m.mem[0xfff] = 0x61;
    m.mem[0x000] = 0x07; // opcode 6107
    m.pc = 0xfff;
    m.run(1);
    assert(m.v[1] == 7 && m.pc == 0x001);
}

@("random numbers follow the LCG")
unittest
{
    auto m = runCode([0xc0ff, 0xc1ff, 0xc20f, 0xc3ff], 4);
    assert(m.v[0] == 0x71 && m.v[1] == 0x47 && m.v[2] == 0x0d);
    assert(m.rng != rngSeed);
    // NN = 0 still advances
    m = runCode([0xc000, 0xc0ff], 2);
    assert(m.v[0] == 0x47);
}

@("timers tick every eighth cycle")
unittest
{
    auto m = runCode([0x6008, 0xf015, 0xf018, 0xf107], 4);
    assert(m.dt == 8 && m.st == 8 && m.v[1] == 8);
    m = runCode([0x6008, 0xf015, 0x1204], 8);
    assert(m.dt == 7);
}

@("FX0A waits and picks the lowest key")
unittest
{
    auto ev = [KeyEvent(3, 0x0300)];
    auto m = runCode([0xf00a], 3, ev);
    assert(m.pc == 0x200 && m.v[0] == 0);
    m = runCode([0xf00a], 4, ev);
    assert(m.pc == 0x202 && m.v[0] == 8);
}

@("EX9E / EXA1 use VX & 0xF")
unittest
{
    auto ev = [KeyEvent(0, 0x0002)];
    auto m = runCode([0x6011, 0xe09e, 0x6105, 0x6206], 4, ev);
    assert(m.v[1] == 0 && m.v[2] == 6);
    m = runCode([0x6011, 0xe0a1, 0x6105, 0x6206], 4, ev);
    assert(m.v[1] == 5 && m.v[2] == 6);
}

@("key events at cycle N never apply")
unittest
{
    auto m = runCode([0xf00a], 2, [KeyEvent(2, 1)]);
    assert(m.keys == 0 && m.pc == 0x200);
}

@("memory instructions: BCD, store, load, index")
unittest
{
    auto m = runCode([0x60fe, 0xa300, 0xf033], 3);
    assert(m.mem[0x300] == 2 && m.mem[0x301] == 5 && m.mem[0x302] == 4);
    m = runCode([0x6001, 0x6102, 0x6203, 0xa400, 0xf255, 0xa400, 0x6000, 0xf265], 8);
    assert(m.mem[0x400] == 1 && m.mem[0x402] == 3);
    assert(m.v[0] == 1 && m.v[1] == 2 && m.v[2] == 3 && m.i == 0x400);
    // wrap of I + k across 0xFFF
    m = runCode([0x6007, 0x6108, 0xaffe, 0xf155], 4);
    assert(m.mem[0xffe] == 7 && m.mem[0xfff] == 8);
}

@("FX1E leaves VF alone and keeps 16 bits; FX29 selects glyphs")
unittest
{
    auto m = runCode([0x6fab, 0xaffe, 0x6005, 0xf01e, 0xf029], 5);
    assert(m.v[15] == 0xab);
    assert(m.i == 0x050 + 25);
    m = runCode([0xafff, 0x60ff, 0xf01e], 3);
    assert(m.i == 0x10fe);
}

@("run can be resumed")
unittest
{
    auto m = runCode([0x6008, 0xf015, 0x1204], 4);
    m.run(4);
    assert(m.cycles == 8 && m.dt == 7);
}
