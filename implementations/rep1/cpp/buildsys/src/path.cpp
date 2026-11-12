#include "kiln/path.hpp"

namespace kiln {

namespace {
bool is_pchar(char c) noexcept {
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' ||
         c == '.' || c == '+' || c == '-';
}
}  // namespace

bool is_identifier(std::string_view s) noexcept {
  if (s.empty()) return false;
  auto alpha = [](char c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'; };
  if (!alpha(s[0])) return false;
  for (char c : s) {
    if (!alpha(c) && !(c >= '0' && c <= '9')) return false;
  }
  return true;
}

bool is_workspace_path(std::string_view s) noexcept {
  if (s.empty() || s.size() > 1024) return false;
  std::size_t start = 0;
  while (true) {
    std::size_t end = s.find('/', start);
    std::string_view comp = s.substr(start, end == std::string_view::npos ? end : end - start);
    if (comp.empty() || comp.size() > 255 || comp == "." || comp == "..") return false;
    for (char c : comp) {
      if (!is_pchar(c)) return false;
    }
    if (end == std::string_view::npos) return true;
    start = end + 1;
  }
}

bool is_reference_shape(std::string_view s) noexcept {
  if (!s.empty() && s[0] == '@') return is_identifier(s.substr(1));
  return is_workspace_path(s);
}

std::string_view first_component(std::string_view path) noexcept {
  return path.substr(0, path.find('/'));
}

bool is_generated_path(std::string_view path) noexcept { return first_component(path) == "out"; }

}  // namespace kiln
