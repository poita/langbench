#pragma once
#include <cstdint>

namespace chip8 {

/// The 32-bit linear congruential generator used by `CXNN`.
///
/// `s = s * 1103515245 + 12345 (mod 2^32)`; the output byte is bits 16..23.
class Rng {
public:
    static constexpr std::uint32_t kDefaultSeed = 0x12345678u;

    explicit constexpr Rng(std::uint32_t seed = kDefaultSeed) noexcept : state_(seed) {}

    /// Advance the generator once and return the next random byte.
    constexpr std::uint8_t next_byte() noexcept {
        state_ = state_ * 1103515245u + 12345u;
        return static_cast<std::uint8_t>((state_ >> 16) & 0xFFu);
    }

    constexpr std::uint32_t state() const noexcept { return state_; }

private:
    std::uint32_t state_;
};

}  // namespace chip8
