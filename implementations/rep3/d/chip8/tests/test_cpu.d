/// Instruction-level tests for chip8.cpu.
module test_cpu;

import chip8;

private Machine boot(const(ubyte)[] rom)
{
    auto m = Machine.create();
    m.loadRom(rom);
    return m;
}

/// Run a ROM given as 16-bit opcodes for `n` cycles.
private Machine exec(const ushort[] ops, ulong n, const(KeyEvent)[] events = null)
{
    ubyte[] rom;
    foreach (op; ops)
        rom ~= [cast(ubyte)(op >> 8), cast(ubyte) op];
    auto m = boot(rom);
    run(m, n, events);
    return m;
}

unittest // zero cycles does nothing
{
    auto m = exec([0x6001], 0);
    assert(m.pc == 0x200 && m.v[0] == 0 && m.cycle == 0);
}

unittest // 7XNN wraps and leaves VF alone
{
    auto m = exec([0x6FAA, 0x60FF, 0x7001], 3);
    assert(m.v[0] == 0 && m.v[0xF] == 0xAA);
}

unittest // 8XY4 carry, VF wins when X == F
{
    auto m = exec([0x60FF, 0x6102, 0x8014], 3);
    assert(m.v[0] == 1 && m.v[0xF] == 1);
    m = exec([0x6FFF, 0x6102, 0x8F14], 3);
    assert(m.v[0xF] == 1);
}

unittest // 8XY5 / 8XY7 borrow flags
{
    auto m = exec([0x6005, 0x6103, 0x8015], 3);
    assert(m.v[0] == 2 && m.v[0xF] == 1);
    m = exec([0x6003, 0x6105, 0x8015], 3);
    assert(m.v[0] == 0xFE && m.v[0xF] == 0);
    m = exec([0x6003, 0x6105, 0x8017], 3);
    assert(m.v[0] == 2 && m.v[0xF] == 1);
    m = exec([0x6005, 0x6103, 0x8017], 3);
    assert(m.v[0] == 0xFE && m.v[0xF] == 0);
}

unittest // shifts act on VX in place
{
    auto m = exec([0x6081, 0x61FF, 0x8016], 3);
    assert(m.v[0] == 0x40 && m.v[0xF] == 1);
    m = exec([0x6081, 0x61FF, 0x801E], 3);
    assert(m.v[0] == 0x02 && m.v[0xF] == 1);
}

unittest // skips
{
    auto m = exec([0x6005, 0x3005, 0x6101, 0x6201], 3);
    assert(m.v[1] == 0 && m.v[2] == 1 && m.pc == 0x208);
    m = exec([0x6005, 0x4005, 0x6101], 3);
    assert(m.v[1] == 1);
}

unittest // call and return
{
    // 200: call 206; 202: 6001; 204: jmp 204; 206: 6102; 208: ret
    auto m = exec([0x2206, 0x6001, 0x1204, 0x6102, 0x00EE], 3);
    assert(m.sp == 0 && m.v[1] == 2 && m.pc == 0x202);
    run(m, 1);
    assert(m.v[0] == 1);
}

unittest // BNNN uses V0 and wraps to 12 bits
{
    auto m = exec([0x60FF, 0xBFFF], 2);
    assert(m.pc == 0x0FE);
}

unittest // undefined opcodes are no-ops
{
    auto m = exec([0x5001, 0x8008, 0x9001, 0xE000, 0xF0FF, 0x0123], 6);
    assert(m.pc == 0x20C);
    foreach (r; m.v) assert(r == 0);
}

unittest // CXNN advances the RNG even with mask 0
{
    auto m = exec([0xC000, 0xC1FF], 2);
    assert(m.v[0] == 0 && m.v[1] == 0x47);
}

unittest // draw wraps, detects collision
{
    auto m = exec([0x6A3E, 0x6B1E, 0x6000, 0xF029, 0xDAB5], 5);
    assert(m.pixel(62, 30) && m.pixel(63, 30) && m.pixel(0, 30) && !m.pixel(2, 30));
    assert(m.pixel(1, 0) && m.pixel(0, 2) && m.pixel(62, 1) && !m.pixel(63, 1) && !m.pixel(0, 0));
    assert(m.v[0xF] == 0);
    m = exec([0x6A3E, 0x6B1E, 0x6000, 0xF029, 0xDAB5, 0xDAB5], 6);
    foreach (r; m.display) assert(r == 0);
    assert(m.v[0xF] == 1);
}

unittest // DXY0 draws nothing and clears VF
{
    auto m = exec([0x6F01, 0xD000], 2);
    assert(m.v[0xF] == 0);
}

unittest // 00E0 clears
{
    auto m = exec([0xF029, 0xD005, 0x00E0], 3);
    foreach (r; m.display) assert(r == 0);
}

unittest // timers tick after every 8th cycle, including the setting cycle
{
    auto m = exec([0x6009, 0xF015, 0xF018], 8);
    assert(m.dt == 8 && m.st == 8);
    m = exec([0x6001, 0xF015, 0xF007, 0x1206], 8);
    assert(m.dt == 0);
}

unittest // FX0A waits, then stores the lowest held key
{
    auto m = exec([0xF30A], 4, [KeyEvent(3, 0x0A00)]);
    assert(m.v[3] == 9 && m.pc == 0x202);
    m = exec([0xF30A], 5);
    assert(m.pc == 0x200 && m.v[3] == 0);
}

unittest // EX9E / EXA1
{
    auto m = exec([0x6003, 0xE09E, 0x6101, 0x6201], 3, [KeyEvent(0, 0x0008)]);
    assert(m.v[1] == 0);
    m = exec([0x6013, 0xE0A1, 0x6101, 0x6201], 3, [KeyEvent(0, 0x0008)]); // key 3 down: no skip
    assert(m.v[1] == 1);
    m = exec([0x6013, 0xE0A1, 0x6101, 0x6201], 3); // key 3 up: skip
    assert(m.v[1] == 0 && m.v[2] == 1);
}

unittest // key events: event at cycle c applies before cycle c
{
    // F00A at 0x200 then self loop
    auto m = exec([0xF00A, 0x1202], 2, [KeyEvent(2, 1)]);
    assert(m.pc == 0x200 || m.pc == 0x202);
    assert(m.keys == 0);
    m = exec([0xF00A, 0x1202], 3, [KeyEvent(1, 0x0002)]);
    assert(m.v[0] == 1);
}

unittest // FX33, FX55, FX65 with address wrap
{
    auto m = exec([0x60FE, 0xAFFF, 0xF033, 0xF265], 4);
    assert(m.mem[0xFFF] == 2 && m.mem[0x000] == 5 && m.mem[0x001] == 4);
    assert(m.v[0] == 2 && m.v[1] == 5 && m.v[2] == 4);
    m = exec([0x6011, 0x6122, 0xAFFF, 0xF155], 4);
    assert(m.mem[0xFFF] == 0x11 && m.mem[0] == 0x22);
}

unittest // FX1E keeps 16 bits, memory access masks
{
    auto m = exec([0xAFFF, 0x60FF, 0xF01E], 3);
    assert(m.i == 0x10FE);
    m = exec([0xAFFF, 0x60FF, 0xF01E, 0x61FF, 0xF11E, 0x6F00], 5);
    assert(m.i == 0x11FD);
}

unittest // fetch across the end of memory
{
    auto m = boot([0x1F, 0xFF]); // jump to 0xFFF
    m.mem[0xFFF] = 0x60;          // low byte from mem[0] = 0 -> 0x6000 (V0 = 0)
    run(m, 2);
    assert(m.pc == 0x001);
}

unittest // run() can be resumed
{
    auto a = exec([0xC0FF, 0xC1FF, 0x1204], 10);
    auto b = boot([0xC0, 0xFF, 0xC1, 0xFF, 0x12, 0x04]);
    run(b, 4);
    run(b, 6);
    assert(a == b);
}
