/// Unit tests for chip8.machine, chip8.font and chip8.output.
module tests.test_machine;

import std.array : appender, replicate;
import std.algorithm : canFind, count, startsWith;
import std.string : splitLines;
import chip8;

/// Builds a machine from hex, runs it and returns it.
private Machine exec(string romHex, ulong cycles, const(KeyEvent)[] events = null)
{
    auto m = makeMachine(parseHex(romHex));
    run(m, cycles, events);
    return m;
}

private string report(string input)
{
    auto p = parseProgram(input);
    auto m = makeMachine(p.rom);
    run(m, p.cycles, p.events);
    return render(m);
}

unittest // font is loaded and ROM placed at 0x200
{
    auto m = makeMachine([0xAB, 0xCD]);
    assert(m.mem[0x050 .. 0x0A0] == fontData[]);
    assert(m.mem[0x200] == 0xAB && m.mem[0x201] == 0xCD);
    assert(m.pc == 0x200);
}

unittest // spec example 1
{
    auto m = exec("60ff7001610180141208", 6);
    assert(m.pc == 0x208 && m.v[0] == 1 && m.v[1] == 1 && m.v[15] == 0);
}

unittest // zero cycles executes nothing
{
    auto m = exec("6001", 0);
    assert(m.pc == 0x200 && m.v[0] == 0);
}

unittest // spec example 2: wrapping sprite, then collision
{
    auto m = exec("6a3e6b1e6000f029dab5dab5", 5);
    assert(m.pc == 0x20a && m.v[15] == 0);
    assert(m.display[30] == 0xC000_0000_0000_0003UL);  // F0 at x=62: columns 62,63,0,1
    assert(m.display[31] == 0x4000_0000_0000_0002UL);  // 90: columns 62 and 1
    assert(m.display[0] == 0x4000_0000_0000_0002UL && m.display[2] == 0xC000_0000_0000_0003UL);
}

unittest // draw twice erases and sets VF
{
    auto m = exec("6a3e6b1e6000f029dab5dab5", 6);
    assert(m.pc == 0x20c && m.v[15] == 1);
    foreach (row; m.display) assert(row == 0);
}

unittest // spec example 3: RNG, timers, keys
{
    auto m = exec("c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a", 14, [KeyEvent(9, 0x0300)]);
    assert(m.v[0] == 8 && m.v[1] == 0x47 && m.v[2] == 0x0d && m.v[4] == 8);
    assert(m.dt == 7 && m.pc == 0x21e);
}

unittest // RNG sequence from the spec
{
    auto m = exec("c0ffc1ffc2ff", 3);
    assert(m.v[0] == 0x71 && m.v[1] == 0x47 && m.v[2] == 0x1d);
    assert(m.rng == 0x2e1d6ab7);
}

unittest // RNG advances even with mask 0
{
    auto m = exec("c000c1ff", 2);
    assert(m.v[1] == 0x47);
}

unittest // flag is written after the result when X == F
{
    // VF = 0xFF; VF += VF -> result 0xFE, then carry flag 1 wins
    auto m = exec("6fff8ff4", 2);
    assert(m.v[15] == 1);
    // VF = 1; VF >>= 1 -> 0, then flag (old low bit) 1 wins
    auto n = exec("6f018ff6", 2);
    assert(n.v[15] == 1);
}

unittest // 8XY5 / 8XY7 borrow flags
{
    auto m = exec("600361058015", 3);        // V0 = 3 - 5
    assert(m.v[0] == 0xFE && m.v[15] == 0);
    auto n = exec("600361058017", 3);        // V0 = 5 - 3
    assert(n.v[0] == 2 && n.v[15] == 1);
    auto e = exec("600561058015", 3);        // equal: no borrow
    assert(e.v[0] == 0 && e.v[15] == 1);
}

unittest // shifts operate in place and ignore VY
{
    auto m = exec("608561ff8016", 3);
    assert(m.v[0] == 0x42 && m.v[15] == 1);
    auto n = exec("60816100801e", 3);
    assert(n.v[0] == 0x02 && n.v[15] == 1);
}

unittest // 8XY4 carry
{
    auto m = exec("60ff61028014", 3);
    assert(m.v[0] == 1 && m.v[15] == 1);
}

unittest // call and return, SP reporting
{
    // 0x200: call 0x206; 0x206: ret
    enum rom = "2206" ~ "0000" ~ "0000" ~ "00ee";
    auto n = exec(rom, 1);
    assert(n.sp == 1 && n.pc == 0x206 && n.stack[0] == 0x202);
    auto m = exec(rom, 2);
    assert(m.sp == 0 && m.pc == 0x202);
}

unittest // full stack
{
    // 16 nested calls each to the next instruction
    string rom;
    foreach (k; 0 .. 16)
    {
        import std.format : format;
        rom ~= format("2%03x", 0x202 + 2 * k);
    }
    auto m = exec(rom, 16);
    assert(m.sp == 16);
}

unittest // skips
{
    auto m = exec("600130011200", 2);    // V0 == 1: skip the jump
    assert(m.pc == 0x206);
    auto n = exec("600140011200", 3);    // 4001 not taken: jump executes
    assert(n.pc == 0x200);
    auto r = exec("60016101" ~ "5010" ~ "9010", 3);   // 5XY0 skips, 9XY0 does not
    assert(r.pc == 0x208);
}

unittest // BNNN uses V0 and masks to 12 bits; odd PC allowed
{
    auto m = exec("6001bfff", 2);
    assert(m.pc == 0x000);
    auto n = exec("6001b300", 2);
    assert(n.pc == 0x301);
}

unittest // fetch wraps from 0xFFF to 0x000
{
    auto m = makeMachine([0x00]);
    m.pc = 0xFFF;
    m.mem[0xFFF] = 0x60;   // 6000|NN : NN read from mem[0]
    m.mem[0] = 0x2A;
    run(m, 1);
    assert(m.v[0] == 0x2A && m.pc == 0x001);
}

unittest // FX33, FX55, FX65 with I wrapping
{
    auto m = exec("60fea000f033", 3);
    assert(m.mem[0] == 2 && m.mem[1] == 5 && m.mem[2] == 4 && m.i == 0);
    auto n = makeMachine(parseHex("6001610262036300a" ~ "ffe" ~ "f355f365"));
    run(n, 7);
    assert(n.mem[0xFFE] == 1 && n.mem[0xFFF] == 2 && n.mem[0] == 3 && n.mem[1] == 0);
    assert(n.i == 0xFFE);
}

unittest // FX1E keeps 16 bits, FX29 maps to font
{
    auto m = exec("afff6002f01e", 3);
    assert(m.i == 0x1001);
    auto w = exec("afff60ff" ~ "f01e" ~ "f01e" ~ "f01e", 5);   // I may exceed 0xFFF
    assert(w.i == ((0xfff + 3 * 0xff) & 0xFFFF));
    auto n = exec("6a1ffa29", 2);
    assert(n.i == 0x050 + 15 * 5);
}

unittest // key skips and wait
{
    auto m = exec("6005e09e1200", 2, [KeyEvent(0, 0x0020)]);   // key 5 down: skip
    assert(m.pc == 0x206);
    auto u = exec("6005e0a11200", 2, [KeyEvent(0, 0x0020)]);   // EXA1: key down, no skip
    assert(u.pc == 0x204);
    auto w = exec("f00a", 3);
    assert(w.pc == 0x200);
    auto k = exec("f00a", 1, [KeyEvent(0, 0x8010)]);           // lowest key wins
    assert(k.v[0] == 4 && k.pc == 0x202);
}

unittest // timers tick after every 8th cycle, and ST too
{
    auto m = exec("60ff" ~ "f015" ~ "f018" ~ "1206", 16);
    assert(m.dt == 0xff - 2 && m.st == 0xff - 2);
}

unittest // unknown opcodes are no-ops
{
    auto m = exec("5121" ~ "8128" ~ "9123" ~ "e000" ~ "f0ff" ~ "0123", 6);
    assert(m.pc == 0x20c);
    foreach (r; m.v) assert(r == 0);
}

unittest // draw with N = 0 clears VF
{
    auto m = exec("6f01d010", 2);
    assert(m.v[15] == 0);
}

unittest // 00E0 clears the display
{
    auto m = exec("f029d005" ~ "00e0", 3);
    foreach (row; m.display) assert(row == 0);
}

unittest // render format
{
    auto text = report("60ff7001610180141208\n6\n");
    auto lines = text.splitLines;
    assert(lines.length == 34);
    foreach (l; lines[0 .. 32]) assert(l == ".".replicate(64));
    assert(lines[32] == "PC=0208 I=0000 SP=0 DT=00 ST=00");
    assert(lines[33] == "V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00");
    assert(text[$ - 1] == '\n');
}

unittest // render shows pixels from the left
{
    auto lines = report("f029d005\n2\n").splitLines;
    assert(lines[0] == "####" ~ ".".replicate(60));
    assert(lines[1] == "#..#" ~ ".".replicate(60));
}
