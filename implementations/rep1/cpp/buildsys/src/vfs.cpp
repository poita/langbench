#include "kiln/vfs.hpp"

#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>

#include "kiln/hash.hpp"
#include "kiln/path.hpp"

namespace kiln {

bool Vfs::is_eligible(std::string_view path) {
  return path != kStateFile && !is_generated_path(path);
}

bool Vfs::exists(std::string_view path) const { return files_.find(path) != files_.end(); }

Vfs::Content Vfs::read(std::string_view path) const {
  auto it = files_.find(path);
  return it == files_.end() ? nullptr : it->second.content;
}

std::uint64_t Vfs::hash(std::string_view path) const {
  auto it = files_.find(path);
  if (it == files_.end()) throw std::out_of_range("Vfs::hash: no such file");
  if (!it->second.hash) it->second.hash = fnv1a64(*it->second.content);
  return *it->second.hash;
}

void Vfs::write(std::string_view path, std::string content) {
  write(path, std::make_shared<const std::string>(std::move(content)));
}

void Vfs::write(std::string_view path, Content content) {
  auto it = files_.find(path);
  if (it == files_.end()) {
    it = files_.emplace(std::string(path), File{}).first;
    if (is_eligible(path)) eligible_.emplace(path);
  }
  it->second.content = std::move(content);
  it->second.hash.reset();
  it->second.stamp = ++clock_;
}

bool Vfs::remove(std::string_view path) {
  auto it = files_.find(path);
  if (it == files_.end()) return false;
  files_.erase(it);
  auto e = eligible_.find(path);
  if (e != eligible_.end()) eligible_.erase(e);
  return true;
}

void Vfs::touch(std::string_view path) {
  auto it = files_.find(path);
  if (it != files_.end()) it->second.stamp = ++clock_;
}

std::uint64_t Vfs::stamp(std::string_view path) const {
  auto it = files_.find(path);
  return it == files_.end() ? 0 : it->second.stamp;
}

std::vector<std::string> Vfs::paths() const {
  std::vector<std::string> out;
  out.reserve(files_.size());
  for (const auto& [p, f] : files_) out.push_back(p);
  return out;
}

std::vector<std::string> Vfs::generated_paths() const {
  std::vector<std::string> out;
  for (const auto& [p, f] : files_) {
    if (p == kStateFile || is_generated_path(p)) out.push_back(p);
  }
  return out;
}

std::vector<std::string> Vfs::eligible_with_prefix(std::string_view prefix) const {
  std::vector<std::string> out;
  for (auto it = eligible_.lower_bound(prefix); it != eligible_.end(); ++it) {
    std::string_view p = *it;
    if (p.substr(0, prefix.size()) != prefix) break;
    out.push_back(*it);
  }
  return out;
}

Vfs Vfs::load_directory(const std::string& dir, std::string_view skip_top_level) {
  namespace fs = std::filesystem;
  Vfs vfs;
  fs::path root(dir);
  for (auto it = fs::recursive_directory_iterator(root); it != fs::recursive_directory_iterator(); ++it) {
    if (!it->is_regular_file()) continue;
    std::string rel = it->path().lexically_relative(root).generic_string();
    if (!skip_top_level.empty() && rel == skip_top_level) continue;
    std::ifstream in(it->path(), std::ios::binary);
    if (!in) throw std::runtime_error("cannot read " + it->path().string());
    std::string data((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    vfs.write(rel, std::move(data));
  }
  return vfs;
}

void Vfs::save_directory(const std::string& dir) const {
  namespace fs = std::filesystem;
  fs::path root(dir);
  fs::create_directories(root);
  for (const auto& [p, f] : files_) {
    fs::path target = root / p;
    fs::create_directories(target.parent_path());
    std::ofstream out(target, std::ios::binary | std::ios::trunc);
    if (!out) throw std::runtime_error("cannot write " + target.string());
    out.write(f.content->data(), static_cast<std::streamsize>(f.content->size()));
  }
}

}  // namespace kiln
