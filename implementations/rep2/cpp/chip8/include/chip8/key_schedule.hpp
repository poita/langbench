#pragma once
#include <cstdint>
#include <string_view>
#include <vector>

namespace chip8 {

/// One key-state change: before cycle `cycle` executes, the held keys become `mask`.
struct KeyEvent {
    std::uint64_t cycle;
    std::uint16_t mask;  ///< bit k set = key k held down
};

/// A strictly cycle-ordered list of key events, consumed front to back.
using KeySchedule = std::vector<KeyEvent>;

/// Parse a schedule of the form `"<cycle>:<mask4hex> ..."` (space separated).
/// An empty string yields an empty schedule. Throws `std::invalid_argument` on
/// malformed text.
KeySchedule parse_key_schedule(std::string_view text);

}  // namespace chip8
