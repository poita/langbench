#include "tessera/render.hpp"

namespace tessera {

std::string format_block(std::size_t line_no, const Outcome& o) {
  std::string out = "[" + std::to_string(line_no) + "] " + o.status + "\n";
  for (const auto& line : o.payload) {
    out += "  ";
    out += line;
    out += '\n';
  }
  return out;
}

std::vector<std::string> render_entries(const std::vector<Entry>& entries) {
  std::vector<std::string> lines;
  lines.reserve(entries.size());
  for (const auto& e : entries) {
    std::string line = render_string(e.key);
    if (e.doc) line += " = " + render(*e.doc);
    lines.push_back(std::move(line));
  }
  return lines;
}

std::vector<std::string> render_stats(const Stats& s) {
  return {
      "pages " + std::to_string(s.pages),
      "free " + std::to_string(s.free_pages),
      "freehead " + std::to_string(s.free_head),
      "docs " + std::to_string(s.docs),
      "root " + std::to_string(s.root),
      "height " + std::to_string(s.height),
      "commits " + std::to_string(s.commits),
      "indexes " + std::to_string(s.indexes),
      "wal " + std::to_string(s.wal_size),
  };
}

std::vector<std::string> render_indexes(const std::vector<IndexInfo>& indexes) {
  std::vector<std::string> lines;
  for (const auto& i : indexes)
    lines.push_back(std::to_string(i.slot) + " " + i.path + " root " + std::to_string(i.root) +
                    " entries " + std::to_string(i.entries));
  return lines;
}

}  // namespace tessera
