#pragma once
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "chip8/key_schedule.hpp"
#include "chip8/machine.hpp"

namespace chip8 {

/// A parsed run request: the ROM, the cycle budget and the key schedule.
struct Program {
    std::vector<std::uint8_t> rom;
    std::uint64_t cycles = 0;
    KeySchedule keys;
};

/// Parse the stdin format of SPEC.md (`rom-hex \n cycles [\n key-schedule]`).
/// Throws `std::invalid_argument` if the text is malformed.
Program parse_program(std::string_view text);

/// Format the machine as the 34-line report of SPEC.md (display, PC/I/SP/DT/ST
/// line, V line), each line ending in '\n'.
std::string format_state(const Machine& machine);

namespace detail {
/// Value of a hex digit (either case), or -1.
int hex_digit(char c) noexcept;
/// Parse an unsigned decimal; throws `std::invalid_argument` on bad/overflowing text.
std::uint64_t parse_decimal(std::string_view s);
}  // namespace detail

}  // namespace chip8
