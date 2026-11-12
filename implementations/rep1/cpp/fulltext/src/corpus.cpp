#include "fulltext/corpus.hpp"

#include <algorithm>
#include <fstream>
#include <iterator>
#include <stdexcept>

namespace fulltext {

namespace fs = std::filesystem;

std::string read_file(const fs::path& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw std::runtime_error("cannot open " + path.string());
  return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

std::vector<Document> load_documents(const fs::path& input_dir) {
  std::vector<Document> docs;
  const fs::path dir = input_dir / "docs";
  std::error_code ec;
  if (!fs::is_directory(dir, ec)) return docs;
  for (fs::directory_iterator it(dir, ec), end; !ec && it != end; it.increment(ec)) {
    std::error_code fec;
    if (!it->is_regular_file(fec)) continue;
    const std::string name = it->path().filename().string();
    if (name.size() < 4 || name.compare(name.size() - 4, 4, ".txt") != 0) continue;
    docs.push_back({name.substr(0, name.size() - 4), read_file(it->path())});
  }
  std::sort(docs.begin(), docs.end(), [](const Document& a, const Document& b) { return a.id < b.id; });
  return docs;
}

}  // namespace fulltext
