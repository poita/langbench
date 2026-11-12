/**
 * A deterministic CHIP-8 interpreter.
 *
 * Importing `chip8` gives access to the whole public API:
 *
 * $(UL
 *   $(LI `chip8.machine`: the `Machine` CPU/memory model and its interpreter loop)
 *   $(LI `chip8.display`: the 64x32 monochrome `Display`)
 *   $(LI `chip8.keys`: the `KeySchedule` that drives the keypad)
 *   $(LI `chip8.rng`: the specified linear congruential generator)
 *   $(LI `chip8.font`: the built-in hexadecimal font)
 *   $(LI `chip8.input`: parsing of the textual program format)
 *   $(LI `chip8.output`: rendering of the final state as text)
 *   $(LI `chip8.cli`: the command-line driver, usable as a function)
 * )
 */
module chip8;

public import chip8.cli;
public import chip8.display;
public import chip8.font;
public import chip8.input;
public import chip8.keys;
public import chip8.machine;
public import chip8.output;
public import chip8.rng;
