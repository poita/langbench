/**
 * A deterministic CHIP-8 interpreter.
 *
 * Modules:
 * $(UL
 *   $(LI `chip8.font`    – built-in hexadecimal font)
 *   $(LI `chip8.rng`     – the specified linear congruential generator)
 *   $(LI `chip8.display` – 64x32 monochrome framebuffer)
 *   $(LI `chip8.machine` – CPU state and the fetch/decode/execute step)
 *   $(LI `chip8.input`   – parsing of the textual job format)
 *   $(LI `chip8.runner`  – cycle loop with key schedule)
 *   $(LI `chip8.output`  – formatting of the final report)
 *   $(LI `chip8.program` – parse + run + format in one call)
 * )
 */
module chip8;

public import chip8.font;
public import chip8.rng;
public import chip8.display;
public import chip8.machine;
public import chip8.input;
public import chip8.runner;
public import chip8.output;
public import chip8.program;
