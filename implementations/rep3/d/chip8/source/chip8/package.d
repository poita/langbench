/++
CHIP-8 interpreter library.

A deterministic CHIP-8 interpreter with fully specified semantics. Import
`chip8` to get everything:

$(UL
    $(LI $(MREF chip8.machine) – machine state and constants)
    $(LI $(MREF chip8.cpu) – the interpreter loop, `run`)
    $(LI $(MREF chip8.input) – parsing the textual program format)
    $(LI $(MREF chip8.output) – formatting the display and CPU state)
)

Example:
---
import chip8;

auto prog = parseProgram("6a3e6b1e6000f029dab5dab5\n5\n");
auto m = Machine.create();
m.loadRom(prog.rom);
run(m, prog.cycles, prog.events);
auto report = formatState(m); // 34 lines of text
---
+/
module chip8;

public import chip8.machine;
public import chip8.cpu;
public import chip8.input;
public import chip8.output;
