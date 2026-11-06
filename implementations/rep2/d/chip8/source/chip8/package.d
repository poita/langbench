/++
    A deterministic CHIP-8 interpreter.

    Import `chip8` to get the whole public API:

    $(UL
        $(LI `chip8.machine`: the `Machine` state and the `run` interpreter loop)
        $(LI `chip8.font`: the built-in hexadecimal font)
        $(LI `chip8.input`: parsing of the textual ROM / cycles / key-schedule format)
        $(LI `chip8.output`: rendering of the display and CPU state as text)
    )
+/
module chip8;

public import chip8.font;
public import chip8.input;
public import chip8.machine;
public import chip8.output;
