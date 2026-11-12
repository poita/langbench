/// The cycle loop: key schedule plus `Machine.step`.
module chip8.runner;

import chip8.input : KeyEvent;
import chip8.machine : Machine;

/**
 * Run `machine` for exactly `cycles` more cycles.
 *
 * `schedule` must be in strictly increasing cycle order; its cycle numbers
 * are absolute (counted from the machine's initial state). Events are
 * consumed in order, O(1) per cycle.
 */
void run(ref Machine machine, ulong cycles, scope const(KeyEvent)[] schedule) @safe pure nothrow @nogc
{
    immutable end = machine.cycles + cycles;
    size_t next = 0;
    while (machine.cycles < end)
    {
        while (next < schedule.length && schedule[next].cycle <= machine.cycles)
            machine.keys = schedule[next++].mask;
        machine.step();
    }
}

@safe pure unittest
{
    // An event at cycle 1 is seen by the EX9E executing in cycle 1, so V1 = 1 is skipped.
    auto m = Machine([0x60, 0x05, 0xE0, 0x9E, 0x61, 0x01, 0x62, 0x01]);
    run(m, 3, [KeyEvent(1, 1 << 5)]);
    assert(m.v[1] == 0 && m.v[2] == 1);
}

@safe pure unittest
{
    // An event at cycle N never has any effect; N = 0 runs nothing.
    auto m = Machine([0x60, 0x05]);
    run(m, 0, [KeyEvent(0, 0xFFFF)]);
    assert(m.cycles == 0 && m.pc == 0x200);
    run(m, 1, [KeyEvent(1, 0xFFFF)]);
    assert(m.keys == 0 && m.v[0] == 5);
}
