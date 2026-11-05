/++
The interpreter loop.

$(LREF run) executes a given number of cycles on a $(REF Machine, chip8,machine).
The whole fetch/decode/execute loop lives in that one function: the hot
scalars are kept in local variables and written back to the machine when the
loop ends. Instructions are decoded from memory on every cycle (nothing is
cached), with a single `switch` on the top nibble of the opcode.
+/
module chip8.cpu;

import core.bitop : bsf, ror;
import chip8.machine;

/// A change of the held-key state, effective immediately before `cycle` executes.
struct KeyEvent
{
    /// Absolute (0-based) cycle number at which the event takes effect.
    ulong cycle;
    /// Key state: bit `k` set means key `k` is held.
    ushort mask;
}

/++
Advance one step of the 32-bit linear congruential generator and return
the random byte derived from the new state.
+/
ubyte nextRandom(ref uint state) pure nothrow @nogc @safe
{
    state = state * 1_103_515_245u + 12_345u;
    return cast(ubyte)(state >> 16);
}

///
unittest
{
    uint s = rngSeed;
    assert(nextRandom(s) == 0x71 && s == 0x0b719151);
    assert(nextRandom(s) == 0x47 && s == 0x6f47bdb6);
    assert(nextRandom(s) == 0x1d && s == 0x2e1d6ab7);
}

/++
XOR an `n`-row sprite read from memory at `index` onto the display with its
origin at (`sx`, `sy`), wrapping at the edges.

Returns: `true` if any lit pixel was turned off.
+/
bool drawSprite(ref ulong[displayHeight] display, scope const(ubyte)[] mem,
    uint sx, uint sy, uint index, uint n) pure nothrow @nogc @safe
{
    ulong hit = 0;
    foreach (row; 0 .. n)
    {
        immutable ulong bits = ror(cast(ulong) mem[(index + row) & 0xFFF] << 56, sx & 63);
        immutable y = (sy + row) & 31;
        hit |= display[y] & bits;
        display[y] ^= bits;
    }
    return hit != 0;
}

/++
Run `cycles` instruction cycles on `m`, starting at cycle number `m.cycle`.

`events` must be sorted by strictly increasing `cycle`. Events whose cycle is
before the starting cycle are ignored (their effect is already in `m.keys`);
an event for cycle `c` is applied immediately before cycle `c` executes.
+/
void run(ref Machine m, ulong cycles, scope const(KeyEvent)[] events = null) pure nothrow @nogc @trusted
{
    // Hot state in locals.
    uint pc = m.pc;
    uint index = m.i;
    uint sp = m.sp;
    uint dt = m.dt;
    uint st = m.st;
    uint keys = m.keys;
    uint rng = m.rng;
    ulong cycle = m.cycle;
    immutable ulong end = cycle + cycles;

    ubyte[] mem = m.mem[];
    ubyte[] v = m.v[];

    size_t ev = 0;
    while (ev < events.length && events[ev].cycle < cycle)
        ev++;
    ulong nextEvent = ev < events.length ? events[ev].cycle : ulong.max;

    for (; cycle < end; cycle++)
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
                m.display[] = 0;
            else if (op == 0x00EE)
            {
                sp--;
                pc = m.stack[sp & 15] & 0xFFF;
            }
            break;
        case 0x1:
            pc = nnn;
            break;
        case 0x2:
            m.stack[sp & 15] = cast(ushort) pc;
            sp++;
            pc = nnn;
            break;
        case 0x3:
            if (v[x] == nn)
                pc = (pc + 2) & 0xFFF;
            break;
        case 0x4:
            if (v[x] != nn)
                pc = (pc + 2) & 0xFFF;
            break;
        case 0x5:
            if ((op & 0xF) == 0 && v[x] == v[y])
                pc = (pc + 2) & 0xFFF;
            break;
        case 0x6:
            v[x] = cast(ubyte) nn;
            break;
        case 0x7:
            v[x] = cast(ubyte)(v[x] + nn);
            break;
        case 0x8:
        {
            immutable uint a = v[x];
            immutable uint b = v[y];
            switch (op & 0xF)
            {
            case 0x0: v[x] = cast(ubyte) b; break;
            case 0x1: v[x] = cast(ubyte)(a | b); break;
            case 0x2: v[x] = cast(ubyte)(a & b); break;
            case 0x3: v[x] = cast(ubyte)(a ^ b); break;
            case 0x4:
                v[x] = cast(ubyte)(a + b);
                v[0xF] = (a + b) > 255;
                break;
            case 0x5:
                v[x] = cast(ubyte)(a - b);
                v[0xF] = a >= b;
                break;
            case 0x6:
                v[x] = cast(ubyte)(a >> 1);
                v[0xF] = a & 1;
                break;
            case 0x7:
                v[x] = cast(ubyte)(b - a);
                v[0xF] = b >= a;
                break;
            case 0xE:
                v[x] = cast(ubyte)(a << 1);
                v[0xF] = (a >> 7) & 1;
                break;
            default:
                break;
            }
            break;
        }
        case 0x9:
            if ((op & 0xF) == 0 && v[x] != v[y])
                pc = (pc + 2) & 0xFFF;
            break;
        case 0xA:
            index = nnn;
            break;
        case 0xB:
            pc = (nnn + v[0]) & 0xFFF;
            break;
        case 0xC:
            v[x] = cast(ubyte)(nextRandom(rng) & nn);
            break;
        case 0xD:
        {
            immutable collided = drawSprite(m.display, mem, v[x] & 63, v[y] & 31, index, op & 0xF);
            v[0xF] = collided;
            break;
        }
        case 0xE:
            if (nn == 0x9E)
            {
                if ((keys >> (v[x] & 0xF)) & 1)
                    pc = (pc + 2) & 0xFFF;
            }
            else if (nn == 0xA1)
            {
                if (!((keys >> (v[x] & 0xF)) & 1))
                    pc = (pc + 2) & 0xFFF;
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
            case 0x1E: index = (index + v[x]) & 0xFFFF; break;
            case 0x29: index = fontStart + (v[x] & 0xF) * 5; break;
            case 0x33:
            {
                immutable uint val = v[x];
                mem[index & 0xFFF] = cast(ubyte)(val / 100);
                mem[(index + 1) & 0xFFF] = cast(ubyte)((val / 10) % 10);
                mem[(index + 2) & 0xFFF] = cast(ubyte)(val % 10);
                break;
            }
            case 0x55:
                foreach (k; 0 .. x + 1)
                    mem[(index + k) & 0xFFF] = v[k];
                break;
            case 0x65:
                foreach (k; 0 .. x + 1)
                    v[k] = mem[(index + k) & 0xFFF];
                break;
            default:
                break;
            }
            break;
        default:
            assert(0); // unreachable: op >> 12 is a nibble
        }

        if (((cycle + 1) & 7) == 0)
        {
            if (dt) dt--;
            if (st) st--;
        }
    }

    m.pc = cast(ushort) pc;
    m.i = cast(ushort) index;
    m.sp = cast(ubyte) sp;
    m.dt = cast(ubyte) dt;
    m.st = cast(ubyte) st;
    m.keys = cast(ushort) keys;
    m.rng = rng;
    m.cycle = cycle;
}

///
unittest
{
    // V0 = 0xFF; V0 += 1; jump to self.
    auto m = Machine.create();
    m.loadRom([0x60, 0xFF, 0x70, 0x01, 0x12, 0x04]);
    run(m, 10);
    assert(m.v[0] == 0 && m.pc == 0x204 && m.cycle == 10);
}
