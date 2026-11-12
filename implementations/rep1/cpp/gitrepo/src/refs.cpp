#include "gitrepo/refs.hpp"

#include "fs_util.hpp"

namespace gitrepo {

namespace {

constexpr int kMaxSymrefDepth = 5;

bool is_space(char c) {
  return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f';
}

/// `HEAD` or `refs/...`, with no empty, `.` or `..` component.
bool is_ref_name(std::string_view name) {
  if (name != "HEAD" && name.substr(0, 5) != "refs/") return false;
  if (name.find('\0') != std::string_view::npos) return false;
  std::size_t pos = 0;
  for (;;) {
    std::size_t slash = name.find('/', pos);
    std::string_view part = name.substr(pos, slash == std::string_view::npos ? std::string_view::npos : slash - pos);
    if (part.empty() || part == "." || part == "..") return false;
    if (slash == std::string_view::npos) return true;
    pos = slash + 1;
  }
}

}  // namespace

RefDatabase::RefDatabase(std::filesystem::path git_dir) : git_dir_(std::move(git_dir)) {
  auto text = detail::read_file(git_dir_ / "packed-refs");
  if (!text) return;
  std::string_view rest = *text;
  while (!rest.empty()) {
    std::size_t eol = rest.find('\n');
    std::string_view line = rest.substr(0, eol);
    rest = eol == std::string_view::npos ? std::string_view() : rest.substr(eol + 1);
    if (line.empty() || line[0] == '#' || line[0] == '^') continue;
    if (line.size() < ObjectId::kHexSize + 2 || line[ObjectId::kHexSize] != ' ') continue;
    auto id = ObjectId::from_hex(line.substr(0, ObjectId::kHexSize));
    if (!id) continue;
    packed_.emplace(std::string(line.substr(ObjectId::kHexSize + 1)), *id);
  }
}

std::optional<ObjectId> RefDatabase::resolve(std::string_view name) const {
  return resolve(name, kMaxSymrefDepth);
}

std::optional<ObjectId> RefDatabase::resolve(std::string_view name, int budget) const {
  if (!is_ref_name(name)) return std::nullopt;
  if (auto text = detail::read_file(git_dir_ / std::string(name))) {
    std::string_view value = *text;
    while (!value.empty() && is_space(value.back())) value.remove_suffix(1);
    if (value.substr(0, 5) == "ref: ") {
      if (budget == 0) return std::nullopt;
      return resolve(value.substr(5), budget - 1);
    }
    return ObjectId::from_hex(value);
  }
  auto it = packed_.find(std::string(name));
  if (it == packed_.end()) return std::nullopt;
  return it->second;
}

}  // namespace gitrepo
