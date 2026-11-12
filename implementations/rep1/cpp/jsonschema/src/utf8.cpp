#include "jsonschema/utf8.hpp"

namespace jsonschema::utf8 {

std::size_t length(std::string_view s) noexcept {
  std::size_t n = 0;
  for (unsigned char c : s) {
    if ((c & 0xC0) != 0x80) ++n;
  }
  return n;
}

std::u32string decode(std::string_view s) {
  std::u32string out;
  out.reserve(s.size());
  std::size_t i = 0;
  const std::size_t n = s.size();
  while (i < n) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    std::size_t extra = 0;
    char32_t cp = 0;
    if (c < 0x80) {
      cp = c;
    } else if ((c & 0xE0) == 0xC0) {
      extra = 1;
      cp = c & 0x1F;
    } else if ((c & 0xF0) == 0xE0) {
      extra = 2;
      cp = c & 0x0F;
    } else if ((c & 0xF8) == 0xF0) {
      extra = 3;
      cp = c & 0x07;
    } else {
      out.push_back(0xFFFD);
      ++i;
      continue;
    }
    if (i + extra >= n) {
      out.push_back(0xFFFD);
      ++i;
      continue;
    }
    bool ok = true;
    for (std::size_t k = 1; k <= extra; ++k) {
      unsigned char cc = static_cast<unsigned char>(s[i + k]);
      if ((cc & 0xC0) != 0x80) {
        ok = false;
        break;
      }
      cp = (cp << 6) | (cc & 0x3F);
    }
    if (!ok) {
      out.push_back(0xFFFD);
      ++i;
      continue;
    }
    out.push_back(cp);
    i += extra + 1;
  }
  return out;
}

void append(std::string& out, char32_t cp) {
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

}  // namespace jsonschema::utf8
