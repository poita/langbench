#include "kiln/path.hpp"

namespace kiln {

namespace {
bool isPathChar(char c) noexcept {
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
         (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '+' || c == '-';
}
}  // namespace

bool isWorkspacePath(std::string_view s) noexcept {
  if (s.empty() || s.size() > 1024) return false;
  std::size_t start = 0;
  while (true) {
    std::size_t end = s.find('/', start);
    std::string_view comp =
        s.substr(start, end == std::string_view::npos ? s.size() - start : end - start);
    if (comp.empty() || comp.size() > 255) return false;
    if (comp == "." || comp == "..") return false;
    for (char c : comp)
      if (!isPathChar(c)) return false;
    if (end == std::string_view::npos) return true;
    start = end + 1;
  }
}

bool isIdentifier(std::string_view s) noexcept {
  if (s.empty()) return false;
  for (std::size_t i = 0; i < s.size(); ++i) {
    char c = s[i];
    bool alpha = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
    bool digit = c >= '0' && c <= '9';
    if (!(alpha || (i > 0 && digit))) return false;
  }
  return true;
}

bool isPhonyRef(std::string_view s) noexcept {
  return !s.empty() && s[0] == '@' && isIdentifier(s.substr(1));
}

bool isGeneratedPath(std::string_view path) noexcept {
  return path == "out" || (path.size() > 3 && path.substr(0, 4) == "out/");
}

}  // namespace kiln
