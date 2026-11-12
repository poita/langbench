#include "chip8/runner.hpp"

namespace chip8 {

void run(Machine& machine, std::uint64_t cycles, const KeySchedule& keys) {
    std::size_t next = 0;
    for (std::uint64_t c = 0; c < cycles; ++c) {
        while (next < keys.size() && keys[next].cycle <= c) machine.set_keys(keys[next++].mask);
        machine.step();
    }
}

Machine run_program(const Program& program) {
    Machine m;
    m.load_rom(program.rom);
    run(m, program.cycles, program.keys);
    return m;
}

}  // namespace chip8
