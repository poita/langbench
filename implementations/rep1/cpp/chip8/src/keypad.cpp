#include "chip8/keypad.hpp"

#include <utility>

namespace chip8 {

int Keypad::lowest_down() const noexcept {
  for (int k = 0; k < 16; ++k) {
    if ((mask_ >> k) & 1u) return k;
  }
  return -1;
}

KeySchedule::KeySchedule(std::vector<KeyEvent> events) : events_(std::move(events)) {}

}  // namespace chip8
