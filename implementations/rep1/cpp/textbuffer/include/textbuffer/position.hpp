#pragma once

/// \file position.hpp
/// Line/column positions inside a document.

#include <compare>
#include <cstdint>
#include <string_view>

namespace textbuffer {

/// A 0-based (line, column) position. Positions order lexicographically:
/// first by line, then by column. A column is both a character and a byte
/// index because documents only contain printable ASCII.
struct Position {
    std::uint32_t line = 0;
    std::uint32_t col = 0;

    friend constexpr auto operator<=>(const Position&, const Position&) = default;
};

/// The position reached by typing \p text (which may contain '\n') at \p start.
Position advance(Position start, std::string_view text);

}  // namespace textbuffer
