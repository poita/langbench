#pragma once
/// @file rng.hpp
/// The deterministic random number generator used by the `CXNN` instruction.

#include <cstdint>

namespace chip8 {

/// 32-bit linear congruential generator specified for CHIP-8 `CXNN`.
///
///     s = s * 1103515245 + 12345 (mod 2^32);  byte = (s >> 16) & 0xFF
class Rng {
 public:
  static constexpr std::uint32_t kDefaultSeed = 0x12345678u;

  constexpr explicit Rng(std::uint32_t seed = kDefaultSeed) noexcept : state_(seed) {}

  /// Advance the generator once and return the next random byte.
  constexpr std::uint8_t next_byte() noexcept {
    state_ = state_ * 1103515245u + 12345u;
    return static_cast<std::uint8_t>((state_ >> 16) & 0xFFu);
  }

  /// Current internal 32-bit state.
  constexpr std::uint32_t state() const noexcept { return state_; }

 private:
  std::uint32_t state_;
};

}  // namespace chip8
