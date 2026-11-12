#pragma once
#include <array>
#include <cstdint>
#include <string>

namespace chip8 {

/// The 64x32 monochrome frame buffer.
class Display {
public:
    static constexpr int kWidth = 64;
    static constexpr int kHeight = 32;

    /// Turn every pixel off.
    void clear() noexcept { pixels_.fill(0); }

    /// True if the pixel at (x, y) is lit. Coordinates are wrapped to the screen.
    bool get(int x, int y) const noexcept { return pixels_[index(x, y)] != 0; }

    /// XOR the pixel at (x, y) (coordinates wrapped). Returns true if the pixel
    /// was lit before, i.e. it has been turned off (a collision).
    bool toggle(int x, int y) noexcept {
        std::uint8_t& p = pixels_[index(x, y)];
        const bool was_on = p != 0;
        p ^= 1;
        return was_on;
    }

    /// Render as 32 lines of 64 characters (`#` lit, `.` unlit), each ending in '\n'.
    std::string to_string() const;

    bool operator==(const Display& o) const noexcept { return pixels_ == o.pixels_; }
    bool operator!=(const Display& o) const noexcept { return !(*this == o); }

private:
    static constexpr std::size_t index(int x, int y) noexcept {
        return static_cast<std::size_t>((y & (kHeight - 1)) * kWidth + (x & (kWidth - 1)));
    }
    std::array<std::uint8_t, kWidth * kHeight> pixels_{};
};

}  // namespace chip8
