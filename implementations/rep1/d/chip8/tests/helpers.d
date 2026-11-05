module tests.helpers;

import chip8;

/// Build a machine, load `code` (big-endian opcodes) and run it for `cycles`.
Machine runCode(const(ushort)[] code, ulong cycles, const(KeyEvent)[] events = null)
{
    ubyte[] rom;
    foreach (op; code)
    {
        rom ~= cast(ubyte)(op >> 8);
        rom ~= cast(ubyte) op;
    }
    Machine m;
    m.reset();
    m.loadRom(rom);
    m.run(cycles, events);
    return m;
}
