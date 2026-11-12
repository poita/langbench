/// The CHIP-8 machine model and its fetch-decode-execute loop.
module chip8.machine;

import chip8.display;
import chip8.font;
import chip8.keys;
import chip8.rng;

/// Size of the address space in bytes.
enum size_t memorySize = 4096;
/// Address at which ROMs are loaded and execution starts.
enum ushort programStart = 0x200;
/// Largest ROM that fits in memory.
enum size_t maxRomSize = memorySize - programStart;
/// Depth of the call stack.
enum size_t stackDepth = 16;

/**
 * The complete state of a CHIP-8 machine.
 *
 * Instructions are fetched and decoded from memory on every cycle, so
 * self-modifying programs behave correctly. All fields are public so that
 * callers can inspect (or set up) state directly.
 */
struct Machine
{
    /// 4 KiB of memory.
    ubyte[memorySize] mem;
    /// Registers `V0`..`VF`.
    ubyte[16] v;
    /// Index register (all 16 bits are kept; masked only when used as an address).
    ushort i;
    /// 12-bit program counter.
    ushort pc = programStart;
    /// Return-address stack.
    ushort[stackDepth] stack;
    /// Number of entries on the stack.
    ubyte sp;
    /// Delay timer.
    ubyte dt;
    /// Sound timer.
    ubyte st;
    /// Currently held keys; bit `k` is key `k`.
    ushort keys;
    /// Random number generator.
    Lcg rng;
    /// Frame buffer.
    Display display;
    /// Number of cycles completed so far.
    ulong cycles;

    /**
     * Creates a machine with the font and `rom` loaded.
     * Throws: `Exception` if `rom` is longer than `maxRomSize`.
     */
    this(scope const(ubyte)[] rom) @safe pure
    {
        if (rom.length > maxRomSize)
            throw new Exception("ROM too large");
        mem[fontBase .. fontBase + fontData.length] = fontData[];
        mem[programStart .. programStart + rom.length] = rom[];
    }

    /**
     * Executes exactly `count` cycles, applying `schedule` along the way.
     * `schedule` must not already have been advanced past the current cycle.
     */
    void run(ulong count, ref KeySchedule schedule) @safe pure nothrow @nogc
    {
        const end = cycles + count;
        while (cycles < end)
        {
            keys = schedule.stateAt(cycles);
            step();
        }
    }

    /// Executes one cycle (fetch, execute, timer tick) with the current `keys`.
    void step() @safe pure nothrow @nogc
    {
        const op = cast(ushort)((mem[pc] << 8) | mem[(pc + 1) & 0xFFF]);
        pc = (pc + 2) & 0xFFF;
        execute(op);
        if (++cycles % 8 == 0)
        {
            if (dt > 0) --dt;
            if (st > 0) --st;
        }
    }

    private void skipIf(bool cond) @safe pure nothrow @nogc
    {
        if (cond)
            pc = (pc + 2) & 0xFFF;
    }

    /// Executes a single already-fetched opcode (PC points past it).
    void execute(ushort op) @safe pure nothrow @nogc
    {
        const x = (op >> 8) & 0xF;
        const y = (op >> 4) & 0xF;
        const n = op & 0xF;
        const nn = cast(ubyte)(op & 0xFF);
        const nnn = cast(ushort)(op & 0xFFF);

        final switch (op >> 12)
        {
        case 0x0:
            if (op == 0x00E0)
                display.clear();
            else if (op == 0x00EE)
                pc = stack[--sp & 0xF] & 0xFFF;
            break;
        case 0x1:
            pc = nnn;
            break;
        case 0x2:
            stack[sp & 0xF] = pc;
            ++sp;
            pc = nnn;
            break;
        case 0x3:
            skipIf(v[x] == nn);
            break;
        case 0x4:
            skipIf(v[x] != nn);
            break;
        case 0x5:
            if (n == 0)
                skipIf(v[x] == v[y]);
            break;
        case 0x6:
            v[x] = nn;
            break;
        case 0x7:
            v[x] = cast(ubyte)(v[x] + nn);
            break;
        case 0x8:
            alu(x, y, n);
            break;
        case 0x9:
            if (n == 0)
                skipIf(v[x] != v[y]);
            break;
        case 0xA:
            i = nnn;
            break;
        case 0xB:
            pc = (nnn + v[0]) & 0xFFF;
            break;
        case 0xC:
            v[x] = rng.next() & nn;
            break;
        case 0xD:
            draw(x, y, n);
            break;
        case 0xE:
            if (nn == 0x9E)
                skipIf((keys >> (v[x] & 0xF)) & 1);
            else if (nn == 0xA1)
                skipIf(!((keys >> (v[x] & 0xF)) & 1));
            break;
        case 0xF:
            misc(x, nn);
            break;
        }
    }

    private void alu(uint x, uint y, uint n) @safe pure nothrow @nogc
    {
        const vx = v[x], vy = v[y];
        switch (n)
        {
        case 0x0: v[x] = vy; break;
        case 0x1: v[x] = vx | vy; break;
        case 0x2: v[x] = vx & vy; break;
        case 0x3: v[x] = vx ^ vy; break;
        case 0x4:
            v[x] = cast(ubyte)(vx + vy);
            v[0xF] = (vx + vy) > 255;
            break;
        case 0x5:
            v[x] = cast(ubyte)(vx - vy);
            v[0xF] = vx >= vy;
            break;
        case 0x6:
            v[x] = vx >> 1;
            v[0xF] = vx & 1;
            break;
        case 0x7:
            v[x] = cast(ubyte)(vy - vx);
            v[0xF] = vy >= vx;
            break;
        case 0xE:
            v[x] = cast(ubyte)(vx << 1);
            v[0xF] = vx >> 7;
            break;
        default:
            break;
        }
    }

    private void draw(uint x, uint y, uint n) @safe pure nothrow @nogc
    {
        ubyte[15] rows = void;
        foreach (r; 0 .. n)
            rows[r] = mem[(i + r) & 0xFFF];
        const hit = display.drawSprite(v[x], v[y], rows[0 .. n]);
        v[0xF] = hit;
    }

    private void misc(uint x, ubyte nn) @safe pure nothrow @nogc
    {
        switch (nn)
        {
        case 0x07:
            v[x] = dt;
            break;
        case 0x0A:
            if (keys == 0)
                pc = (pc - 2) & 0xFFF;
            else
            {
                ubyte k = 0;
                while (!((keys >> k) & 1))
                    ++k;
                v[x] = k;
            }
            break;
        case 0x15: dt = v[x]; break;
        case 0x18: st = v[x]; break;
        case 0x1E:
            i = cast(ushort)(i + v[x]);
            break;
        case 0x29:
            i = cast(ushort)glyphAddress(v[x]);
            break;
        case 0x33:
            const b = v[x];
            mem[i & 0xFFF] = b / 100;
            mem[(i + 1) & 0xFFF] = (b / 10) % 10;
            mem[(i + 2) & 0xFFF] = b % 10;
            break;
        case 0x55:
            foreach (k; 0 .. x + 1)
                mem[(i + k) & 0xFFF] = v[k];
            break;
        case 0x65:
            foreach (k; 0 .. x + 1)
                v[k] = mem[(i + k) & 0xFFF];
            break;
        default:
            break;
        }
    }
}

version (unittest)
{
    private Machine load(const(ubyte)[] rom) @safe pure
    {
        return Machine(rom);
    }

    private Machine runRom(const(ubyte)[] rom, ulong n, KeyEvent[] ev = null) @safe pure
    {
        auto m = load(rom);
        auto s = KeySchedule(ev);
        m.run(n, s);
        return m;
    }
}

@safe pure unittest // arithmetic and self loop (spec example 1)
{
    auto m = runRom([0x60, 0xff, 0x70, 0x01, 0x61, 0x01, 0x80, 0x14, 0x12, 0x08], 6);
    assert(m.pc == 0x208 && m.v[0] == 1 && m.v[1] == 1 && m.v[0xF] == 0);
}

@safe pure unittest // zero cycles
{
    auto m = runRom([0x60, 0x01], 0);
    assert(m.pc == 0x200 && m.v[0] == 0 && m.cycles == 0);
}

@safe pure unittest // flag written after result when X == F
{
    // VF = 0xFF; VF += 0x01 -> flag 1 wins; VF = 0x10; VF >>= 1 -> flag 0
    auto m = runRom([0x6f, 0xff, 0x60, 0x01, 0x8f, 0x04], 3);
    assert(m.v[0xF] == 1);
    m = runRom([0x6f, 0x11, 0x8f, 0x06], 2);
    assert(m.v[0xF] == 1); // 0x11 & 1
    m = runRom([0x6f, 0x10, 0x8f, 0x06], 2);
    assert(m.v[0xF] == 0);
}

@safe pure unittest // subtraction flags
{
    auto m = runRom([0x60, 0x05, 0x61, 0x03, 0x80, 0x15], 3); // 5 - 3
    assert(m.v[0] == 2 && m.v[0xF] == 1);
    m = runRom([0x60, 0x03, 0x61, 0x05, 0x80, 0x15], 3); // 3 - 5
    assert(m.v[0] == 0xFE && m.v[0xF] == 0);
    m = runRom([0x60, 0x03, 0x61, 0x05, 0x80, 0x17], 3); // 5 - 3
    assert(m.v[0] == 2 && m.v[0xF] == 1);
}

@safe pure unittest // call / return and stack depth
{
    // 0x200: CALL 0x206; 0x202: LD V1,7; 0x204: JP 0x204; 0x206: LD V0,5; 0x208: RET
    auto m = runRom([0x22, 0x06, 0x61, 0x07, 0x12, 0x04, 0x60, 0x05, 0x00, 0xEE], 1);
    assert(m.sp == 1 && m.pc == 0x206 && m.stack[0] == 0x202);
    m = runRom([0x22, 0x06, 0x61, 0x07, 0x12, 0x04, 0x60, 0x05, 0x00, 0xEE], 3);
    assert(m.sp == 0 && m.pc == 0x202 && m.v[0] == 5);
}

@safe pure unittest // PC wraps through 0xFFF and BNNN
{
    auto m = Machine([0x60, 0x01]);
    m.pc = 0xFFF;
    m.mem[0xFFF] = 0x61;
    m.mem[0x000] = 0x09; // opcode 0x6109
    m.step();
    assert(m.v[1] == 9 && m.pc == 0x001);

    m = runRom([0x60, 0x03, 0xB2, 0x00], 2);
    assert(m.pc == 0x203);
}

@safe pure unittest // memory ops wrap at 0xFFF
{
    auto m = Machine([0x60, 0x01]);
    m.i = 0xFFF;
    m.v[0] = 234;
    m.execute(0xF033);
    assert(m.mem[0xFFF] == 2 && m.mem[0] == 3 && m.mem[1] == 4);
    m.v[0] = 1; m.v[1] = 2;
    m.execute(0xF155);
    assert(m.mem[0xFFF] == 1 && m.mem[0] == 2);
    m.v[0] = m.v[1] = 0;
    m.execute(0xF165);
    assert(m.v[0] == 1 && m.v[1] == 2 && m.i == 0xFFF);
    m.execute(0xF01E);
    assert(m.i == cast(ushort)(0xFFF + 1));
}

@safe pure unittest // timers tick after the instruction, every 8th cycle
{
    // V0=20; DT=V0 (cycle 1); then loop
    auto m = runRom([0x60, 20, 0xF0, 0x15, 0x12, 0x04], 8);
    assert(m.dt == 19);
    m = runRom([0x60, 20, 0xF0, 0x15, 0x12, 0x04], 16);
    assert(m.dt == 18);
}

@safe pure unittest // FX0A waits, then takes the lowest key (spec example 3 tail)
{
    auto m = runRom([0xF0, 0x0A], 3, [KeyEvent(2, 0x0300)]);
    assert(m.v[0] == 8 && m.pc == 0x202);
    m = runRom([0xF0, 0x0A], 3);
    assert(m.pc == 0x200);
}

@safe pure unittest // key skips and a key event at cycle N never applies
{
    auto m = runRom([0x60, 0x03, 0xE0, 0x9E, 0x61, 0x01, 0x62, 0x01], 3, [KeyEvent(1, 0x0008)]);
    assert(m.v[1] == 0 && m.v[2] == 1);
    m = runRom([0x60, 0x03, 0xE0, 0x9E, 0x61, 0x01], 3, [KeyEvent(3, 0x0008)]);
    assert(m.keys == 0 && m.pc == 0x206);
}

@safe pure unittest // sprite drawing with wrap and collision (spec example 2)
{
    static immutable ubyte[12] rom = [0x6a, 0x3e, 0x6b, 0x1e, 0x60, 0x00, 0xf0, 0x29, 0xda, 0xb5, 0xda, 0xb5];
    auto m = runRom(rom[], 5);
    assert(m.v[0xF] == 0 && m.display.litCount == 14);
    assert(m.display[62, 30] && m.display[1, 1] && m.display[0, 2] && !m.display[0, 3]);
    m = runRom(rom[], 6);
    assert(m.v[0xF] == 1 && m.display.litCount == 0);
}

@safe pure unittest // random numbers
{
    auto m = runRom([0xC0, 0xFF, 0xC1, 0xFF, 0xC2, 0x0F, 0xC3, 0x00], 4);
    assert(m.v[0] == 0x71 && m.v[1] == 0x47 && m.v[2] == 0x0d && m.v[3] == 0);
    assert(m.rng.state != 0x2e1d_6ab7); // advanced even with NN = 0
}

@safe pure unittest // unknown opcodes are no-ops
{
    auto m = runRom([0x51, 0x21, 0x80, 0x18, 0x90, 0x13, 0xE0, 0x00, 0xF0, 0xFF, 0x01, 0x23], 6);
    assert(m.pc == 0x20c && m.v == (ubyte[16]).init && m.sp == 0);
}

@safe pure unittest // self-modifying code is executed
{
    // I=0x208; V0=0x62; V1=0x77; store V0,V1 at 0x208; cycle 4 runs 0x6277
    auto m = runRom([0xA2, 0x08, 0x60, 0x62, 0x61, 0x77, 0xF1, 0x55, 0x00, 0x00], 5);
    assert(m.v[2] == 0x77 && m.pc == 0x20a);
}
