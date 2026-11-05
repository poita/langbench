/// Machine state and the interpreter loop.
module chip8.machine;

import core.bitop : bsf;
import chip8.constants;
import chip8.display;
import chip8.rng;

/// A change of the held-key set, effective immediately before `cycle` executes.
struct KeyEvent
{
    /// 0-based cycle number at which the event takes effect.
    ulong cycle;
    /// 16-bit key state: bit `k` set means key `k` is held down.
    ushort mask;
}

/++
    A complete CHIP-8 machine. All state is public so that it can be inspected
    and set up directly; `run` executes cycles on it.
+/
struct Machine
{
    /// 4 KiB of memory.
    ubyte[memorySize] mem;
    /// Registers V0..VF (VF is the flag register).
    ubyte[16] v;
    /// Return-address stack.
    ushort[stackDepth] stack;
    /// Stack pointer: the number of entries on the stack.
    uint sp;
    /// Program counter (12 bits).
    ushort pc = programStart;
    /// Index register (16 bits).
    ushort i;
    /// Delay timer.
    ubyte dt;
    /// Sound timer.
    ubyte st;
    /// Currently held keys, bit `k` for key `k`.
    ushort keys;
    /// RNG state.
    uint rng = rngSeed;
    /// The display.
    Display display;
    /// Number of cycles executed so far (drives the timer tick phase).
    ulong cycles;

    /// Reset to power-on state: zeroed memory except the font, PC = 0x200.
    void reset() pure nothrow @safe @nogc
    {
        this = Machine.init;
        mem[fontStart .. fontStart + fontData.length] = fontData[];
    }

    /// Copy `rom` into memory at `0x200`. At most `maxRomSize` bytes are loaded.
    void loadRom(const(ubyte)[] rom) pure nothrow @safe @nogc
    {
        immutable n = rom.length < maxRomSize ? rom.length : maxRomSize;
        mem[programStart .. programStart + n] = rom[0 .. n];
    }

    /++
        Execute `count` further cycles.

        `events` must be sorted by strictly increasing cycle and cycle numbers
        are absolute (counted from the machine's first cycle, so they continue
        across successive calls to `run`). Events whose cycle has already
        passed are ignored.
    +/
    void run(ulong count, const(KeyEvent)[] events = null) pure nothrow @trusted @nogc
    {
        // Hot state lives in locals for the duration of the loop.
        ubyte[] mem = this.mem[];
        ubyte[16] v = this.v;
        ushort[stackDepth] stack = this.stack;
        uint sp = this.sp;
        uint pc = this.pc;
        uint idx = this.i;
        uint dt = this.dt;
        uint st = this.st;
        uint keys = this.keys;
        uint rng = this.rng;
        Display* disp = &this.display;
        immutable ulong start = this.cycles;
        immutable ulong end = start + count;

        size_t ev = 0;
        while (ev < events.length && events[ev].cycle < start)
            ev++;
        ulong nextEvent = ev < events.length ? events[ev].cycle : ulong.max;

        for (ulong cycle = start; cycle < end; cycle++)
        {
            if (cycle == nextEvent)
            {
                keys = events[ev].mask;
                ev++;
                nextEvent = ev < events.length ? events[ev].cycle : ulong.max;
            }

            immutable uint op = (cast(uint) mem[pc] << 8) | mem[(pc + 1) & 0xFFF];
            pc = (pc + 2) & 0xFFF;
            immutable uint x = (op >> 8) & 0xF;
            immutable uint y = (op >> 4) & 0xF;
            immutable uint nn = op & 0xFF;
            immutable uint nnn = op & 0xFFF;

            switch (op >> 12)
            {
            case 0x0:
                if (op == 0x00E0)
                    disp.clear();
                else if (op == 0x00EE)
                {
                    sp--;
                    pc = stack[sp & 15];
                }
                break;
            case 0x1:
                pc = nnn;
                break;
            case 0x2:
                stack[sp & 15] = cast(ushort) pc;
                sp++;
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
                    immutable a = v[x], b = v[y];
                    v[x] = cast(ubyte)(a - b);
                    v[15] = a >= b;
                    break;
                }
                case 0x6:
                {
                    immutable a = v[x];
                    v[x] = a >> 1;
                    v[15] = a & 1;
                    break;
                }
                case 0x7:
                {
                    immutable a = v[x], b = v[y];
                    v[x] = cast(ubyte)(b - a);
                    v[15] = b >= a;
                    break;
                }
                case 0xE:
                {
                    immutable a = v[x];
                    v[x] = cast(ubyte)(a << 1);
                    v[15] = a >> 7;
                    break;
                }
                default: break;
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
                rng = rngNext(rng);
                v[x] = rngByte(rng) & nn;
                break;
            case 0xD:
            {
                immutable sx = v[x] & 63;
                immutable sy = v[y] & 31;
                immutable n = op & 0xF;
                bool hit = false;
                foreach (row; 0 .. n)
                    hit |= disp.xorByte(sx, sy + row, mem[(idx + row) & 0xFFF]);
                v[15] = hit;
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
                case 0x29: idx = fontStart + (v[x] & 0xF) * glyphSize; break;
                case 0x33:
                {
                    immutable a = v[x];
                    mem[idx & 0xFFF] = cast(ubyte)(a / 100);
                    mem[(idx + 1) & 0xFFF] = cast(ubyte)((a / 10) % 10);
                    mem[(idx + 2) & 0xFFF] = cast(ubyte)(a % 10);
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
                default: break;
                }
                break;
            default:
                break;
            }

            if (((cycle + 1) & (timerPeriod - 1)) == 0)
            {
                if (dt) dt--;
                if (st) st--;
            }
        }

        this.v = v;
        this.stack = stack;
        this.sp = sp;
        this.pc = cast(ushort) pc;
        this.i = cast(ushort) idx;
        this.dt = cast(ubyte) dt;
        this.st = cast(ubyte) st;
        this.keys = cast(ushort) keys;
        this.rng = rng;
        this.cycles = end;
    }
}
