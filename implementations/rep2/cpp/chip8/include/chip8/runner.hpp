#pragma once
#include <cstdint>

#include "chip8/key_schedule.hpp"
#include "chip8/machine.hpp"
#include "chip8/program.hpp"

namespace chip8 {

/// Run `machine` for `cycles` cycles, applying `keys` as they fall due. Events
/// are consumed in order (O(1) per cycle). Event cycles `>= cycles` have no
/// effect; events with cycles below the machine's current cycle count are applied
/// at the first cycle.
void run(Machine& machine, std::uint64_t cycles, const KeySchedule& keys);

/// Build a machine from `program`, run it to completion and return it.
Machine run_program(const Program& program);

}  // namespace chip8
