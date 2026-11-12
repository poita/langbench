#include "spreadsheet/cell_ref.h"

#include <algorithm>

namespace spreadsheet {

std::optional<CellRef> make_cell_ref(std::string_view letters, std::string_view digits) {
  if (letters.empty() || letters.size() > 2 || digits.empty() || digits.size() > 4) {
    return std::nullopt;
  }
  if (digits[0] == '0') return std::nullopt;
  int col = 0;
  for (char c : letters) {
    if (c < 'A' || c > 'Z') return std::nullopt;
    col = col * 26 + (c - 'A' + 1);
  }
  int row = 0;
  for (char c : digits) {
    if (c < '0' || c > '9') return std::nullopt;
    row = row * 10 + (c - '0');
  }
  if (row < 1 || row > kMaxRow) return std::nullopt;
  CellRef ref;
  ref.col = static_cast<std::uint16_t>(col);
  ref.row = static_cast<std::uint16_t>(row);
  return ref;
}

std::optional<CellRef> parse_cell_ref(std::string_view text) {
  std::size_t i = 0;
  while (i < text.size() && text[i] >= 'A' && text[i] <= 'Z') ++i;
  return make_cell_ref(text.substr(0, i), text.substr(i));
}

std::string to_string(CellRef ref) {
  std::string out;
  if (ref.col > 26) out += static_cast<char>('A' + (ref.col - 1) / 26 - 1);
  out += static_cast<char>('A' + (ref.col - 1) % 26);
  out += std::to_string(ref.row);
  return out;
}

CellRange CellRange::spanning(CellRef a, CellRef b) {
  CellRange r;
  r.first.col = std::min(a.col, b.col);
  r.first.row = std::min(a.row, b.row);
  r.last.col = std::max(a.col, b.col);
  r.last.row = std::max(a.row, b.row);
  return r;
}

}  // namespace spreadsheet
