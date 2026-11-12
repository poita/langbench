#include "mime/mailbox.hpp"

#include <algorithm>
#include <fstream>
#include <iterator>
#include <sstream>
#include <stdexcept>

namespace mime {
namespace fs = std::filesystem;

namespace {

std::string read_file(const fs::path& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw std::runtime_error("cannot read " + path.string());
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

}  // namespace

std::vector<RawMessage> split_mbox(std::string_view data) {
  // Offsets of separator lines: (line start, first byte after terminator).
  std::vector<std::pair<std::size_t, std::size_t>> seps;
  bool prev_empty = true;  // the first line counts as preceded by an empty line
  std::size_t pos = 0;
  while (pos < data.size()) {
    std::size_t nl = data.find('\n', pos);
    std::size_t end = nl == std::string_view::npos ? data.size() : nl;
    std::size_t next = nl == std::string_view::npos ? data.size() : nl + 1;
    std::string_view line = data.substr(pos, end - pos);
    if (prev_empty && line.substr(0, 5) == "From ") seps.emplace_back(pos, next);
    bool empty = line.empty() || (nl != std::string_view::npos && line == "\r");
    prev_empty = empty;
    pos = next;
  }

  std::vector<RawMessage> out;
  for (std::size_t i = 0; i < seps.size(); ++i) {
    std::size_t from = seps[i].second;
    std::size_t to = i + 1 < seps.size() ? seps[i + 1].first : data.size();
    std::string_view msg = data.substr(from, to - from);
    if (msg.size() >= 2 && msg[msg.size() - 1] == '\n' && msg[msg.size() - 2] == '\n')
      msg.remove_suffix(1);
    out.push_back({"mbox:" + std::to_string(i + 1), std::string(msg)});
  }
  return out;
}

std::vector<RawMessage> read_eml_directory(const fs::path& dir) {
  std::vector<std::string> names;
  for (const fs::directory_entry& e : fs::directory_iterator(dir)) {
    std::string name = e.path().filename().string();
    if (name.size() >= 4 && name.compare(name.size() - 4, 4, ".eml") == 0 && e.is_regular_file())
      names.push_back(std::move(name));
  }
  std::sort(names.begin(), names.end());  // byte-wise (char traits compare unsigned)
  std::vector<RawMessage> out;
  for (std::string& name : names) {
    std::string bytes = read_file(dir / name);
    out.push_back({std::move(name), std::move(bytes)});
  }
  return out;
}

std::vector<RawMessage> read_mailbox(const fs::path& path) {
  if (fs::is_directory(path)) return read_eml_directory(path);
  return split_mbox(read_file(path));
}

}  // namespace mime
