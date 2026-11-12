/// CPU state and the fetch/decode/execute step.
module chip8.machine;

import chip8.display;
import chip8.font;
import chip8.rng;

/// Size of the address space.
enum size_t memorySize = 4096;
/// Address at which ROMs are loaded and execution starts.
enum ushort programStart = 0x200;
/// Largest ROM that fits above `programStart`.
enum size_t maxRomSize = memorySize - programStart;
/// Number of stack entries.
enum size_t stackDepth = 16;
/// Timers tick once every this many cycles.
enum ulong timerPeriod = 8;

/// Complete machine state.
struct Machine
{
    ubyte[memorySize] memory;     /// RAM; font and ROM are installed by `reset`/`load`.
    ubyte[16] v;                  /// Registers V0..VF (VF is the flag register).
    ushort[stackDepth] stack;     /// Return addresses.
    ushort pc = programStart;     /// Program counter (12 bits).
    ushort i;                     /// Index register (16 bits).
    ubyte sp;                     /// Number of stack entries in use.
    ubyte dt;                     /// Delay timer.
    ubyte st;                     /// Sound timer.
    ushort keys;                  /// Held keys; bit k set means key k is down.
    Lcg rng;                      /// Random number generator.
    Display display;              /// Frame buffer.
    ulong cycles;                 /// Cycles completed so far.

    /// A fresh machine: font installed, `rom` loaded at 0x200.
    /// Throws: Exception if the ROM is empty or too large.
    this(scope const(ubyte)[] rom) @safe pure
    {
        if (rom.length == 0 || rom.length > maxRomSize)
            throw new Exception("ROM must be between 1 and 3584 bytes");
        memory[fontBase .. fontBase + fontData.length] = fontData[];
        memory[programStart .. programStart + rom.length] = rom[];
    }

    /// Execute exactly one cycle (fetch, execute, timer tick).
    /// Key state is set separately through `keys`.
    void step() @safe pure nothrow @nogc
    {
        immutable op = (memory[pc] << 8) | memory[(pc + 1) & 0xFFF];
        pc = (pc + 2) & 0xFFF;
        execute(cast(ushort) op);

        if (++cycles % timerPeriod == 0)
        {
            if (dt > 0) --dt;
            if (st > 0) --st;
        }
    }

    private void skipIf(bool cond) @safe pure nothrow @nogc
    {
        if (cond) pc = (pc + 2) & 0xFFF;
    }

    private void execute(ushort op) @safe pure nothrow @nogc
    {
        immutable x = (op >> 8) & 0xF;
        immutable y = (op >> 4) & 0xF;
        immutable n = op & 0xF;
        immutable nn = cast(ubyte)(op & 0xFF);
        immutable nnn = cast(ushort)(op & 0xFFF);

        switch (op >> 12)
        {
        case 0x0:
            if (op == 0x00E0) display.clear();
            else if (op == 0x00EE) { --sp; pc = stack[sp & 0xF] & 0xFFF; }
            break;
        case 0x1: pc = nnn; break;
        case 0x2:
            stack[sp & 0xF] = pc;
            ++sp;
            pc = nnn;
            break;
        case 0x3: skipIf(v[x] == nn); break;
        case 0x4: skipIf(v[x] != nn); break;
        case 0x5: if (n == 0) skipIf(v[x] == v[y]); break;
        case 0x6: v[x] = nn; break;
        case 0x7: v[x] = cast(ubyte)(v[x] + nn); break;
        case 0x8: alu(x, y, n); break;
        case 0x9: if (n == 0) skipIf(v[x] != v[y]); break;
        case 0xA: i = nnn; break;
        case 0xB: pc = (nnn + v[0]) & 0xFFF; break;
        case 0xC: v[x] = rng.next() & nn; break;
        case 0xD: draw(x, y, n); break;
        case 0xE:
            if (nn == 0x9E) skipIf(((keys >> (v[x] & 0xF)) & 1) != 0);
            else if (nn == 0xA1) skipIf(((keys >> (v[x] & 0xF)) & 1) == 0);
            break;
        case 0xF: misc(x, nn); break;
        default: break;
        }
    }

    private void alu(uint x, uint y, uint n) @safe pure nothrow @nogc
    {
        immutable vx = v[x];
        immutable vy = v[y];
        ubyte flag;
        switch (n)
        {
        case 0x0: v[x] = vy; return;
        case 0x1: v[x] = vx | vy; return;
        case 0x2: v[x] = vx & vy; return;
        case 0x3: v[x] = vx ^ vy; return;
        case 0x4: v[x] = cast(ubyte)(vx + vy); flag = (vx + vy) > 255; break;
        case 0x5: v[x] = cast(ubyte)(vx - vy); flag = vx >= vy; break;
        case 0x6: v[x] = vx >> 1; flag = vx & 1; break;
        case 0x7: v[x] = cast(ubyte)(vy - vx); flag = vy >= vx; break;
        case 0xE: v[x] = cast(ubyte)(vx << 1); flag = (vx >> 7) & 1; break;
        default: return;
        }
        v[0xF] = flag;
    }

    private void draw(uint x, uint y, uint n) @safe pure nothrow @nogc
    {
        immutable sx = v[x] & 63;
        immutable sy = v[y] & 31;
        bool collided = false;
        foreach (row; 0 .. n)
            collided |= display.xorRow(sx, sy + row, memory[(i + row) & 0xFFF]);
        v[0xF] = collided;
    }

    private void misc(uint x, ubyte nn) @safe pure nothrow @nogc
    {
        switch (nn)
        {
        case 0x07: v[x] = dt; break;
        case 0x0A:
            if (keys == 0)
                pc = (pc - 2) & 0xFFF;
            else
            {
                foreach (k; 0 .. 16)
                    if ((keys >> k) & 1) { v[x] = cast(ubyte) k; break; }
            }
            break;
        case 0x15: dt = v[x]; break;
        case 0x18: st = v[x]; break;
        case 0x1E: i = cast(ushort)(i + v[x]); break;
        case 0x29: i = glyphAddress(v[x]); break;
        case 0x33:
            immutable b = v[x];
            memory[i & 0xFFF] = b / 100;
            memory[(i + 1) & 0xFFF] = (b / 10) % 10;
            memory[(i + 2) & 0xFFF] = b % 10;
            break;
        case 0x55:
            foreach (k; 0 .. x + 1) memory[(i + k) & 0xFFF] = v[k];
            break;
        case 0x65:
            foreach (k; 0 .. x + 1) v[k] = memory[(i + k) & 0xFFF];
            break;
        default: break;
        }
    }
}

@safe pure unittest
{
    // The flag is written after the result, so VF wins when X = F.
    auto m = Machine([0x6F, 0xFF, 0x7F, 0x02, 0x8F, 0xF4]);
    foreach (_; 0 .. 3) m.step();
    // 6FFF, 7F02 (VF = 0x01, no flag), 8FF4: VF + VF = 2, no carry -> flag 0 wins.
    assert(m.v[0xF] == 0);
}

@safe pure unittest
{
    // 8XY5 sets VF = 1 when there is no borrow; 8XY7 is the mirror image.
    auto m = Machine([0x60, 0x05, 0x61, 0x07, 0x80, 0x15]);
    foreach (_; 0 .. 3) m.step();
    assert(m.v[0] == 0xFE && m.v[0xF] == 0);

    auto n = Machine([0x60, 0x05, 0x61, 0x07, 0x80, 0x17]);
    foreach (_; 0 .. 3) n.step();
    assert(n.v[0] == 2 && n.v[0xF] == 1);
}

@safe pure unittest
{
    // Shifts work in place; VY is ignored.
    auto m = Machine([0x60, 0x03, 0x80, 0x16, 0x61, 0x81, 0x81, 0x2E]);
    foreach (_; 0 .. 2) m.step();
    assert(m.v[0] == 1 && m.v[0xF] == 1);
    foreach (_; 0 .. 2) m.step();
    assert(m.v[1] == 0x02 && m.v[0xF] == 1);
}

@safe pure unittest
{
    // Opcode fetch wraps from 0xFFF to 0x000; PC is masked.
    auto m = Machine([0x00]);
    m.memory[0xFFF] = 0x12;
    m.memory[0x000] = 0x34;
    m.pc = 0xFFF;
    m.step();
    assert(m.pc == 0x234);
}

@safe pure unittest
{
    // BCD and register block transfers wrap at 12 bits; I is unchanged.
    auto m = Machine([0x60, 0xFE, 0xAF, 0xFF, 0xF0, 0x33, 0xF2, 0x65]);
    foreach (_; 0 .. 4) m.step();
    assert(m.memory[0xFFF] == 2 && m.memory[0] == 5 && m.memory[1] == 4);
    assert(m.i == 0xFFF);
    assert(m.v[0] == 2 && m.v[1] == 5 && m.v[2] == 4);
}

@safe pure unittest
{
    // FX0A waits for a key, then takes the lowest one; timers tick every 8th cycle.
    auto m = Machine([0x60, 0x09, 0xF0, 0x15, 0xF1, 0x0A]);
    foreach (_; 0 .. 4) m.step();
    assert(m.pc == 0x204 && m.v[1] == 0 && m.dt == 9);   // waiting
    m.keys = 0b1100_0000;
    m.step();
    assert(m.v[1] == 6 && m.pc == 0x206);
    foreach (_; 0 .. 3) m.step();                         // cycles 6..8 execute no-ops
    assert(m.cycles == 8 && m.dt == 8);
}

@safe pure unittest
{
    // Machine construction rejects empty and oversized ROMs.
    import std.exception : assertThrown;
    assertThrown(Machine([]));
    assertThrown(Machine(new ubyte[maxRomSize + 1]));
    auto m = Machine(new ubyte[maxRomSize]);
    assert(m.memory[0xFFF] == 0);
}
