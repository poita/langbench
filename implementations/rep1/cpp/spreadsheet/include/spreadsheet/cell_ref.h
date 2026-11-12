// Cell addresses ("A1".."ZZ9999").
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace spreadsheet {

inline constexpr int kMaxColumn = 702;   // "ZZ"
inline constexpr int kMaxRow = 9999;

/// A cell address. Columns are 1..702 (A..Z, AA..ZZ), rows 1..9999.
struct CellRef {
  std::uint16_t col = 0;
  std::uint16_t row = 0;

  /// Key that sorts in row-major order (row first, then column).
  constexpr std::uint32_t key() const {
    return (static_cast<std::uint32_t>(row) << 10) | col;
  }
  friend constexpr bool operator==(CellRef a, CellRef b) { return a.key() == b.key(); }
  friend constexpr bool operator!=(CellRef a, CellRef b) { return a.key() != b.key(); }
  friend constexpr bool operator<(CellRef a, CellRef b) { return a.key() < b.key(); }
};

/// Parses a cell name such as "B12". The whole string must be a valid
/// reference: one or two uppercase letters, then a row 1..9999 written in
/// decimal without leading zeros. Returns nullopt otherwise.
std::optional<CellRef> parse_cell_ref(std::string_view text);

/// Builds a CellRef from already-split parts: `letters` (uppercase) and
/// `digits`. Returns nullopt if the reference is not valid (see above).
std::optional<CellRef> make_cell_ref(std::string_view letters, std::string_view digits);

/// Formats a reference back to its name ("AB123").
std::string to_string(CellRef ref);

/// An inclusive rectangle of cells; corners are normalised so that
/// first <= last in both dimensions.
struct CellRange {
  CellRef first;
  CellRef last;

  static CellRange spanning(CellRef a, CellRef b);
  std::size_t cell_count() const {
    return static_cast<std::size_t>(last.col - first.col + 1) * (last.row - first.row + 1);
  }
};

}  // namespace spreadsheet
