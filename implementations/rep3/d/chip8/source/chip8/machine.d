/++
Machine state of the CHIP-8 interpreter and the constants that describe it.

The state is deliberately a flat, fixed-size `struct` (no heap allocation) so
that it can be copied, compared and inspected freely, and so the interpreter
loop in $(MREF chip8.cpu) can keep the hot scalars in registers.
+/
module chip8.machine;

/// Size of the address space in bytes.
enum memorySize = 4096;
/// Address at which the ROM is loaded and at which execution starts.
enum programStart = 0x200;
/// Address of the built-in font (16 glyphs of 5 bytes).
enum fontStart = 0x050;
/// Largest ROM that fits between `programStart` and the end of memory.
enum maxRomSize = memorySize - programStart;
/// Number of display columns.
enum displayWidth = 64;
/// Number of display rows.
enum displayHeight = 32;
/// Number of return-address slots on the call stack.
enum stackDepth = 16;
/// Initial state of the random number generator.
enum rngSeed = 0x1234_5678;

/// The built-in 4x5 hexadecimal font, glyphs `0`..`F`.
immutable ubyte[80] fontData = [
    0xF0, 0x90, 0x90, 0x90, 0xF0,  0x20, 0x60, 0x20, 0x20, 0x70,
    0xF0, 0x10, 0xF0, 0x80, 0xF0,  0xF0, 0x10, 0xF0, 0x10, 0xF0,
    0x90, 0x90, 0xF0, 0x10, 0x10,  0xF0, 0x80, 0xF0, 0x10, 0xF0,
    0xF0, 0x80, 0xF0, 0x90, 0xF0,  0xF0, 0x10, 0x20, 0x40, 0x40,
    0xF0, 0x90, 0xF0, 0x90, 0xF0,  0xF0, 0x90, 0xF0, 0x10, 0xF0,
    0xF0, 0x90, 0xF0, 0x90, 0x90,  0xE0, 0x90, 0xE0, 0x90, 0xE0,
    0xF0, 0x80, 0x80, 0x80, 0xF0,  0xE0, 0x90, 0x90, 0x90, 0xE0,
    0xF0, 0x80, 0xF0, 0x80, 0xF0,  0xF0, 0x80, 0xF0, 0x80, 0x80,
];

/// Thrown when a ROM cannot be loaded.
class RomException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/++
Complete state of a CHIP-8 machine.

The display is stored as 32 row words; column 0 is the most significant bit
of a row, column 63 the least significant. Use $(LREF Machine.pixel) rather
than relying on that layout.
+/
struct Machine
{
    /// 4 KiB of memory. Every access is masked to 12 bits by the interpreter.
    ubyte[memorySize] mem;
    /// Registers `V0`..`VF`; `VF` doubles as the flag register.
    ubyte[16] v;
    /// Return addresses (12 bits each).
    ushort[stackDepth] stack;
    /// Display rows, column 0 in the most significant bit.
    ulong[displayHeight] display;
    /// Program counter (12 bits).
    ushort pc = programStart;
    /// Index register (16 bits; masked to 12 bits only when used as an address).
    ushort i;
    /// Number of entries on the stack.
    ubyte sp;
    /// Delay timer.
    ubyte dt;
    /// Sound timer.
    ubyte st;
    /// Held keys: bit `k` set means key `k` is down.
    ushort keys;
    /// State of the linear congruential random number generator.
    uint rng = rngSeed;
    /// Number of cycles executed so far.
    ulong cycle;

    /// A fresh machine: font installed, everything else zero.
    static Machine create() pure nothrow @nogc @safe
    {
        Machine m;
        m.mem[fontStart .. fontStart + fontData.length] = fontData[];
        return m;
    }

    /// Copy `rom` to `programStart`. Throws $(LREF RomException) if it does not fit.
    void loadRom(scope const(ubyte)[] rom) pure @safe
    {
        if (rom.length > maxRomSize)
            throw new RomException("ROM too large");
        mem[programStart .. programStart + rom.length] = rom[];
    }

    /// Whether the pixel at column `x` (0-63), row `y` (0-31) is lit.
    bool pixel(size_t x, size_t y) const pure nothrow @nogc @safe
    in (x < displayWidth && y < displayHeight)
    {
        return ((display[y] >> (displayWidth - 1 - x)) & 1) != 0;
    }
}

///
unittest
{
    auto m = Machine.create();
    assert(m.pc == 0x200 && m.rng == 0x12345678);
    assert(m.mem[fontStart] == 0xF0);
    m.loadRom([0x60, 0x01]);
    assert(m.mem[0x200] == 0x60 && m.mem[0x201] == 0x01);
    assert(!m.pixel(0, 0));
}
