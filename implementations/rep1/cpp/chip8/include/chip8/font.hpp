#pragma once
/// @file font.hpp
/// The built-in hexadecimal font.

#include <array>
#include <cstddef>
#include <cstdint>

namespace chip8 {

constexpr std::uint16_t kFontBase = 0x050;       ///< address of glyph '0'
constexpr std::size_t kFontGlyphBytes = 5;       ///< bytes per glyph
constexpr std::size_t kFontBytes = 16 * kFontGlyphBytes;

/// The 80 font bytes (glyphs 0..F, five bytes each).
const std::array<std::uint8_t, kFontBytes>& font_data() noexcept;

/// Address of the glyph for the low nibble of @p digit.
constexpr std::uint16_t font_address(std::uint8_t digit) noexcept {
  return static_cast<std::uint16_t>(kFontBase + (digit & 0xF) * kFontGlyphBytes);
}

}  // namespace chip8
