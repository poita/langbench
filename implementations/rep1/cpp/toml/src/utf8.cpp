#include "toml/utf8.hpp"

namespace toml {

bool is_valid_utf8(std::string_view s) {
  const auto* p = reinterpret_cast<const unsigned char*>(s.data());
  const std::size_t n = s.size();
  std::size_t i = 0;
  while (i < n) {
    unsigned char c = p[i];
    if (c < 0x80) {
      ++i;
      continue;
    }
    std::size_t len;
    char32_t cp, min;
    if (c >= 0xC2 && c <= 0xDF) {
      len = 2, cp = c & 0x1F, min = 0x80;
    } else if (c >= 0xE0 && c <= 0xEF) {
      len = 3, cp = c & 0x0F, min = 0x800;
    } else if (c >= 0xF0 && c <= 0xF4) {
      len = 4, cp = c & 0x07, min = 0x10000;
    } else {
      return false;
    }
    if (n - i < len) return false;
    for (std::size_t k = 1; k < len; ++k) {
      if ((p[i + k] & 0xC0) != 0x80) return false;
      cp = (cp << 6) | (p[i + k] & 0x3F);
    }
    if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
    i += len;
  }
  return true;
}

void append_utf8(std::string& out, char32_t cp) {
  if (cp < 0x80) {
    out.push_back(static_cast<char>(cp));
  } else if (cp < 0x800) {
    out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp < 0x10000) {
    out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else {
    out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  }
}

}  // namespace toml
