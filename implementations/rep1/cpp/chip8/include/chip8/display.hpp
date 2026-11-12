#pragma once
/// @file display.hpp
/// The 64x32 monochrome display.

#include <array>
#include <cstdint>
#include <string>

namespace chip8 {

/// 64x32 one-bit frame buffer with XOR sprite drawing and wrap-around.
class Display {
 public:
  static constexpr int kWidth = 64;
  static constexpr int kHeight = 32;

  /// Turn every pixel off.
  void clear() noexcept { pixels_.fill(0); }

  /// True if the pixel at (x, y) is lit. Coordinates are reduced modulo the size.
  bool pixel(int x, int y) const noexcept { return pixels_[index(x, y)] != 0; }

  /// XOR the pixel at (x, y) (coordinates wrap). Returns true if it was lit
  /// before (i.e. it has just been turned off).
  bool toggle(int x, int y) noexcept {
    std::uint8_t& p = pixels_[index(x, y)];
    const bool was_on = p != 0;
    p ^= 1;
    return was_on;
  }

  /// XOR a sprite of @p rows 8-pixel-wide rows (one byte each, MSB leftmost)
  /// with its origin at (x, y), both reduced modulo the display size. Pixels
  /// beyond an edge wrap around. @p row_at(i) must return the byte for row i.
  /// Returns true if any lit pixel was turned off (the CHIP-8 collision flag).
  template <typename RowFn>
  bool draw_sprite(int x, int y, int rows, RowFn&& row_at) noexcept {
    const int sx = x & (kWidth - 1);
    const int sy = y & (kHeight - 1);
    bool collision = false;
    for (int row = 0; row < rows; ++row) {
      const unsigned byte = row_at(row);
      const int py = (sy + row) & (kHeight - 1);
      for (int bit = 0; bit < 8; ++bit) {
        if ((byte >> (7 - bit)) & 1u) {
          collision |= toggle((sx + bit) & (kWidth - 1), py);
        }
      }
    }
    return collision;
  }

  /// Render as kHeight lines of kWidth characters ('#' lit, '.' unlit), each
  /// terminated by '\n'.
  std::string to_text() const;

  bool operator==(const Display& other) const noexcept { return pixels_ == other.pixels_; }
  bool operator!=(const Display& other) const noexcept { return !(*this == other); }

 private:
  static constexpr std::size_t index(int x, int y) noexcept {
    return static_cast<std::size_t>((y & (kHeight - 1)) * kWidth + (x & (kWidth - 1)));
  }

  std::array<std::uint8_t, kWidth * kHeight> pixels_{};
};

}  // namespace chip8
