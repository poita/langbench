#include "mdiff/lines.hpp"

namespace mdiff {

Lines split_lines(std::string_view text) {
  Lines out;
  std::size_t pos = 0;
  while (pos < text.size()) {
    std::size_t nl = text.find('\n', pos);
    if (nl == std::string_view::npos) {
      out.push_back(text.substr(pos));
      break;
    }
    out.push_back(text.substr(pos, nl - pos));
    pos = nl + 1;
  }
  return out;
}

LineId Interner::intern(Line line) {
  auto [it, inserted] = ids_.try_emplace(line, static_cast<LineId>(ids_.size()));
  (void)inserted;
  return it->second;
}

std::vector<LineId> Interner::intern_all(const Lines& lines) {
  std::vector<LineId> out;
  out.reserve(lines.size());
  ids_.reserve(ids_.size() + lines.size());
  for (Line l : lines) out.push_back(intern(l));
  return out;
}

}  // namespace mdiff
