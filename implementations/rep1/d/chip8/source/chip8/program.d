/// One-call front end: text in, report out.
module chip8.program;

import chip8.input : parseJob;
import chip8.machine : Machine;
import chip8.output : report;
import chip8.runner : run;

/// Parse `input` (see SPEC.md), run the machine and return the 34-line report.
/// Throws: `ParseException` on malformed input.
string simulate(scope const(char)[] input) @safe pure
{
    auto job = parseJob(input);
    auto machine = Machine(job.rom);
    run(machine, job.cycles, job.schedule);
    return report(machine);
}

@safe pure unittest
{
    // SPEC.md example 1.
    enum tail = "PC=0208 I=0000 SP=0 DT=00 ST=00\nV=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n";
    auto r = simulate("60ff7001610180141208\n6\n");
    assert(r.length == 65 * 32 + tail.length);
    assert(r[65 * 32 .. $] == tail);
}

@safe pure unittest
{
    // SPEC.md example 2: wrap-around drawing, then collision on redraw.
    auto r = simulate("6a3e6b1e6000f029dab5dab5\n5\n");
    assert(r[0 .. 65] == ".#............................................................#.\n");
    assert(r[2 * 65 .. 3 * 65] == "##............................................................##\n");
    assert(r[30 * 65 .. 31 * 65] == "##............................................................##\n");
    assert(r[65 * 32 .. $] ==
        "PC=020a I=0050 SP=0 DT=00 ST=00\nV=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 00\n");
    auto r6 = simulate("6a3e6b1e6000f029dab5dab5\n6\n");
    assert(r6[65 * 32 .. $] ==
        "PC=020c I=0050 SP=0 DT=00 ST=00\nV=00 00 00 00 00 00 00 00 00 00 3e 1e 00 00 00 01\n");
    foreach (c; r6[0 .. 65 * 32])
        assert(c != '#');
}

@safe pure unittest
{
    // SPEC.md example 3: RNG, timers and key schedule.
    auto r = simulate("c0ffc1ffc20f6408f415f007e2a11200e4a1120af00a\n14\n9:0300\n");
    assert(r[65 * 32 .. $] ==
        "PC=021e I=0000 SP=0 DT=07 ST=00\nV=08 47 0d 00 08 00 00 00 00 00 00 00 00 00 00 00\n");
}

@safe pure unittest
{
    // Subroutine calls fill the stack; SP is reported in decimal.
    auto r = simulate("2200\n1\n");
    assert(r[65 * 32 .. $] ==
        "PC=0200 I=0000 SP=1 DT=00 ST=00\nV=00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00\n");
}
