/++
    A deterministic CHIP-8 interpreter.

    The library is split by responsibility:

    $(UL
        $(LI `chip8.constants` – machine dimensions and the built-in font)
        $(LI `chip8.display`   – the 64×32 bit-packed display)
        $(LI `chip8.rng`       – the linear congruential generator behind `CXNN`)
        $(LI `chip8.machine`   – machine state and the fetch/decode/execute loop)
        $(LI `chip8.input`     – parsing of the textual input format)
        $(LI `chip8.output`    – rendering of the final state as text)
    )

    Example:
    ---
    import chip8;

    auto m = Machine.init;
    m.reset();
    m.loadRom([0x60, 0x2a, 0x12, 0x02]); // V0 = 0x2a; jump to self
    m.run(100);
    assert(m.v[0] == 0x2a);
    ---
+/
module chip8;

public import chip8.constants;
public import chip8.display;
public import chip8.input;
public import chip8.machine;
public import chip8.output;
public import chip8.rng;
