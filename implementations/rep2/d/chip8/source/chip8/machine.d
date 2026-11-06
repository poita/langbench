/++
    The CHIP-8 machine state and the interpreter loop.

    The semantics are those of the project SPEC: 12-bit masked memory access,
    shifts in place, `FX55`/`FX65` leaving `I` untouched, wrapping sprites,
    a timer tick every eighth cycle and a fixed-seed LCG.
+/
module chip8.machine;

import core.bitop : bsf, ror;
import chip8.font : fontBase, fontData, glyphSize;

/// Size of the address space in bytes.
enum memorySize = 4096;
/// Address at which the ROM is loaded and execution starts.
enum romBase = 0x200;
/// Display width in pixels (one bit of a row word each).
enum displayWidth = 64;
/// Display height in pixels (rows).
enum displayHeight = 32;
/// Number of entries on the call stack.
enum stackDepth = 16;
/// Initial RNG state.
enum rngSeed = 0x12345678;

/// A key-state change taking effect immediately before cycle `cycle`.
struct KeyEvent
{
    /// 0-based cycle number.
    ulong cycle;
    /// Bit `k` set means key `k` is held down.
    ushort mask;
}

/// Complete state of a CHIP-8 machine.
struct Machine
{
    /// Main memory.
    ubyte[memorySize] mem;
    /// Registers `V0`..`VF`.
    ubyte[16] v;
    /// Return addresses.
    ushort[stackDepth] stack;
    /// Program counter (12 bits).
    ushort pc = romBase;
    /// Index register (16 bits).
    ushort i;
    /// Number of entries on the stack.
    ubyte sp;
    /// Delay timer.
    ubyte dt;
    /// Sound timer.
    ubyte st;
    /// Currently held keys, bit `k` for key `k`.
    ushort keys;
    /// LCG state.
    uint rng = rngSeed;
    /// Display rows; bit 63 is column 0.
    ulong[displayHeight] display;
}

/// Returns a machine with the font and `rom` loaded; the ROM is truncated at the end of memory.
Machine makeMachine(const(ubyte)[] rom) @safe pure nothrow @nogc
{
    Machine m;
    m.mem[fontBase .. fontBase + fontData.length] = fontData[];
    immutable n = rom.length < memorySize - romBase ? rom.length : memorySize - romBase;
    m.mem[romBase .. romBase + n] = rom[0 .. n];
    return m;
}

/++
    Executes exactly `cycles` instruction cycles on `m`.

    `events` must be sorted by strictly increasing cycle. The hot scalars live
    in locals for the duration of the loop and are written back at the end.
+/
void run(ref Machine m, ulong cycles, const(KeyEvent)[] events = null) @trusted pure nothrow @nogc
{
    ubyte* mem = m.mem.ptr;
    ubyte* v = m.v.ptr;
    ushort* stack = m.stack.ptr;
    ulong* disp = m.display.ptr;

    uint pc = m.pc;
    uint idx = m.i;
    uint sp = m.sp;
    uint dt = m.dt;
    uint st = m.st;
    uint keys = m.keys;
    uint rng = m.rng;
    size_t next = 0;
    ulong nextCycle = events.length ? events[0].cycle : ulong.max;

    for (ulong cycle = 0; cycle < cycles; ++cycle)
    {
        if (cycle == nextCycle)
        {
            keys = events[next].mask;
            ++next;
            nextCycle = next < events.length ? events[next].cycle : ulong.max;
        }

        immutable uint op = mem[pc] << 8 | mem[(pc + 1) & 0xFFF];
        pc = (pc + 2) & 0xFFF;
        immutable uint x = (op >> 8) & 0xF;
        immutable uint y = (op >> 4) & 0xF;
        immutable uint nn = op & 0xFF;
        immutable uint nnn = op & 0xFFF;

        switch (op >> 12)
        {
        case 0x0:
            if (op == 0x00E0)
                m.display[] = 0;
            else if (op == 0x00EE)
            {
                --sp;
                pc = stack[sp & 15];
            }
            break;
        case 0x1:
            pc = nnn;
            break;
        case 0x2:
            stack[sp & 15] = cast(ushort) pc;
            ++sp;
            pc = nnn;
            break;
        case 0x3:
            if (v[x] == nn) pc = (pc + 2) & 0xFFF;
            break;
        case 0x4:
            if (v[x] != nn) pc = (pc + 2) & 0xFFF;
            break;
        case 0x5:
            if ((op & 0xF) == 0 && v[x] == v[y]) pc = (pc + 2) & 0xFFF;
            break;
        case 0x6:
            v[x] = cast(ubyte) nn;
            break;
        case 0x7:
            v[x] = cast(ubyte)(v[x] + nn);
            break;
        case 0x8:
            switch (op & 0xF)
            {
            case 0x0: v[x] = v[y]; break;
            case 0x1: v[x] |= v[y]; break;
            case 0x2: v[x] &= v[y]; break;
            case 0x3: v[x] ^= v[y]; break;
            case 0x4:
            {
                immutable sum = cast(uint) v[x] + v[y];
                v[x] = cast(ubyte) sum;
                v[15] = sum > 255;
                break;
            }
            case 0x5:
            {
                immutable vx = v[x], vy = v[y];
                v[x] = cast(ubyte)(vx - vy);
                v[15] = vx >= vy;
                break;
            }
            case 0x6:
            {
                immutable vx = v[x];
                v[x] = cast(ubyte)(vx >> 1);
                v[15] = vx & 1;
                break;
            }
            case 0x7:
            {
                immutable vx = v[x], vy = v[y];
                v[x] = cast(ubyte)(vy - vx);
                v[15] = vy >= vx;
                break;
            }
            case 0xE:
            {
                immutable vx = v[x];
                v[x] = cast(ubyte)(vx << 1);
                v[15] = vx >> 7;
                break;
            }
            default:
                break;
            }
            break;
        case 0x9:
            if ((op & 0xF) == 0 && v[x] != v[y]) pc = (pc + 2) & 0xFFF;
            break;
        case 0xA:
            idx = nnn;
            break;
        case 0xB:
            pc = (nnn + v[0]) & 0xFFF;
            break;
        case 0xC:
            rng = rng * 1_103_515_245u + 12_345u;
            v[x] = cast(ubyte)((rng >> 16) & nn);
            break;
        case 0xD:
        {
            immutable sx = v[x] & 63;
            immutable sy = v[y] & 31;
            uint hit = 0;
            foreach (row; 0 .. op & 0xF)
            {
                immutable bits = ror(cast(ulong) mem[(idx + row) & 0xFFF] << 56, sx);
                ulong* line = disp + ((sy + row) & 31);
                hit |= (*line & bits) != 0;
                *line ^= bits;
            }
            v[15] = cast(ubyte) hit;
            break;
        }
        case 0xE:
            if (nn == 0x9E)
            {
                if ((keys >> (v[x] & 0xF)) & 1) pc = (pc + 2) & 0xFFF;
            }
            else if (nn == 0xA1)
            {
                if (!((keys >> (v[x] & 0xF)) & 1)) pc = (pc + 2) & 0xFFF;
            }
            break;
        case 0xF:
            switch (nn)
            {
            case 0x07: v[x] = cast(ubyte) dt; break;
            case 0x0A:
                if (keys)
                    v[x] = cast(ubyte) bsf(keys);
                else
                    pc = (pc - 2) & 0xFFF;
                break;
            case 0x15: dt = v[x]; break;
            case 0x18: st = v[x]; break;
            case 0x1E: idx = (idx + v[x]) & 0xFFFF; break;
            case 0x29: idx = fontBase + (v[x] & 0xF) * glyphSize; break;
            case 0x33:
            {
                immutable vx = v[x];
                mem[idx & 0xFFF] = cast(ubyte)(vx / 100);
                mem[(idx + 1) & 0xFFF] = cast(ubyte)((vx / 10) % 10);
                mem[(idx + 2) & 0xFFF] = cast(ubyte)(vx % 10);
                break;
            }
            case 0x55:
                foreach (k; 0 .. x + 1)
                    mem[(idx + k) & 0xFFF] = v[k];
                break;
            case 0x65:
                foreach (k; 0 .. x + 1)
                    v[k] = mem[(idx + k) & 0xFFF];
                break;
            default:
                break;
            }
            break;
        default:
            break;
        }

        if (((cycle + 1) & 7) == 0)
        {
            if (dt) --dt;
            if (st) --st;
        }
    }

    m.pc = cast(ushort) pc;
    m.i = cast(ushort) idx;
    m.sp = cast(ubyte) sp;
    m.dt = cast(ubyte) dt;
    m.st = cast(ubyte) st;
    m.keys = cast(ushort) keys;
    m.rng = rng;
}
