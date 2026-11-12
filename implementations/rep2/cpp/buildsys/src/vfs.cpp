#include "kiln/vfs.hpp"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <stdexcept>

#include "kiln/hash.hpp"
#include "kiln/path.hpp"

namespace kiln {

bool Vfs::globEligible(const std::string& path) {
  return !isGeneratedPath(path) && path != ".kiln-state";
}

bool Vfs::exists(const std::string& path) const { return files_.count(path) != 0; }

Content Vfs::read(const std::string& path) const {
  auto it = files_.find(path);
  return it == files_.end() ? nullptr : it->second.content;
}

std::uint64_t Vfs::hash(const std::string& path) const {
  auto it = files_.find(path);
  if (it == files_.end()) return fnv1a({});
  const Entry& e = it->second;
  if (!e.hashed) {
    e.hash = fnv1a(*e.content);
    e.hashed = true;
  }
  return e.hash;
}

void Vfs::write(const std::string& path, std::string content) {
  write(path, std::make_shared<const std::string>(std::move(content)));
}

void Vfs::write(const std::string& path, Content content) {
  auto it = files_.find(path);
  if (it == files_.end()) {
    it = files_.emplace(path, Entry{}).first;
    if (globEligible(path)) globIndex_.insert(path);
  }
  Entry& e = it->second;
  // Identical content keeps its cached hash.
  if (e.content && (e.content == content || *e.content == *content)) {
    e.stamp = ++clock_;
    return;
  }
  e.content = std::move(content);
  e.hashed = false;
  e.stamp = ++clock_;
}

bool Vfs::remove(const std::string& path) {
  auto it = files_.find(path);
  if (it == files_.end()) return false;
  files_.erase(it);
  globIndex_.erase(path);
  return true;
}

void Vfs::touch(const std::string& path) {
  auto it = files_.find(path);
  if (it != files_.end()) it->second.stamp = ++clock_;
}

std::vector<std::string> Vfs::glob(const GlobPattern& pattern) const {
  std::vector<std::string> out;
  const std::string& prefix = pattern.literalPrefix();
  for (auto it = globIndex_.lower_bound(prefix); it != globIndex_.end(); ++it) {
    const std::string& p = *it;
    if (p.compare(0, prefix.size(), prefix) != 0) break;
    if (pattern.matches(p)) out.push_back(p);
  }
  return out;
}

std::vector<std::string> Vfs::generatedPaths() const {
  std::vector<std::string> out;
  for (const auto& [path, e] : files_) {
    (void)e;
    if (isGeneratedPath(path) || path == ".kiln-state") out.push_back(path);
  }
  return out;  // std::map iteration is already sorted
}

Vfs Vfs::loadDirectory(const std::string& dir, const std::string& skipName) {
  namespace fs = std::filesystem;
  Vfs vfs;
  fs::path root(dir);
  for (auto it = fs::recursive_directory_iterator(root); it != fs::recursive_directory_iterator(); ++it) {
    if (!it->is_regular_file()) continue;
    std::string rel = it->path().lexically_relative(root).generic_string();
    if (!skipName.empty() && rel == skipName) continue;
    std::ifstream in(it->path(), std::ios::binary);
    std::ostringstream ss;
    ss << in.rdbuf();
    vfs.write(rel, ss.str());
  }
  return vfs;
}

void Vfs::writeDirectory(const std::string& dir) const {
  namespace fs = std::filesystem;
  fs::create_directories(dir);
  for (const auto& [path, e] : files_) {
    fs::path target = fs::path(dir) / path;
    fs::create_directories(target.parent_path());
    std::ofstream out(target, std::ios::binary | std::ios::trunc);
    if (!out) throw std::runtime_error("cannot write " + target.string());
    out.write(e.content->data(), static_cast<std::streamsize>(e.content->size()));
  }
}

}  // namespace kiln
