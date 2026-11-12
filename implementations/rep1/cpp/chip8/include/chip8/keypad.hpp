#pragma once
/// @file keypad.hpp
/// Key state and the time-indexed key schedule.

#include <cstddef>
#include <cstdint>
#include <vector>

namespace chip8 {

/// Sixteen keys packed in a 16-bit mask; bit k set means key k is held.
class Keypad {
 public:
  constexpr Keypad() noexcept = default;
  constexpr explicit Keypad(std::uint16_t mask) noexcept : mask_(mask) {}

  constexpr void set_mask(std::uint16_t mask) noexcept { mask_ = mask; }
  constexpr std::uint16_t mask() const noexcept { return mask_; }

  /// Whether key (@p key & 0xF) is down.
  constexpr bool is_down(std::uint8_t key) const noexcept { return (mask_ >> (key & 0xF)) & 1u; }

  /// Index of the lowest-numbered key that is down, or -1 if none.
  int lowest_down() const noexcept;

 private:
  std::uint16_t mask_ = 0;
};

/// A change of keypad state taking effect immediately before @p cycle runs.
struct KeyEvent {
  std::uint64_t cycle;
  std::uint16_t mask;
};

/// Ordered key events consumed incrementally by a cursor: O(1) per cycle.
class KeySchedule {
 public:
  KeySchedule() = default;
  /// @p events must be in strictly increasing order of cycle.
  explicit KeySchedule(std::vector<KeyEvent> events);

  const std::vector<KeyEvent>& events() const noexcept { return events_; }

  /// Cycle of the next unconsumed event; UINT64_MAX when exhausted.
  std::uint64_t next_cycle() const noexcept {
    return next_ < events_.size() ? events_[next_].cycle : UINT64_MAX;
  }

  /// Consume and return the event due at @p cycle, if any (nullptr otherwise).
  /// Must be called with non-decreasing cycles.
  const KeyEvent* take_due(std::uint64_t cycle) noexcept {
    if (next_ < events_.size() && events_[next_].cycle == cycle) return &events_[next_++];
    return nullptr;
  }

  /// Rewind the cursor to the first event.
  void rewind() noexcept { next_ = 0; }

 private:
  std::vector<KeyEvent> events_;
  std::size_t next_ = 0;
};

}  // namespace chip8
