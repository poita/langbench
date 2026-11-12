#include "text_util.h"

namespace commonmark::detail {

void append_utf8(std::string& out, std::uint32_t cp) {
  if (cp == 0 || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) cp = 0xFFFD;
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

namespace {

int hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return c - 'A' + 10;
}

bool starts_with_at(std::string_view s, std::size_t pos, std::string_view prefix) {
  return s.size() - pos >= prefix.size() && s.compare(pos, prefix.size(), prefix) == 0;
}

}  // namespace

std::size_t match_entity(std::string_view s, std::size_t pos, std::string& out) {
  const std::size_t n = s.size();
  std::size_t i = pos + 1;  // after '&'
  if (i >= n) return 0;
  if (s[i] == '#') {
    ++i;
    std::uint32_t value = 0;
    std::size_t digits = 0;
    if (i < n && (s[i] == 'x' || s[i] == 'X')) {
      ++i;
      while (i < n && is_xdigit(s[i]) && digits < 7) {
        value = value * 16 + static_cast<std::uint32_t>(hex_value(s[i]));
        ++digits;
        ++i;
      }
      if (digits < 1 || digits > 6) return 0;
    } else {
      while (i < n && is_digit(s[i]) && digits < 8) {
        value = value * 10 + static_cast<std::uint32_t>(s[i] - '0');
        ++digits;
        ++i;
      }
      if (digits < 1 || digits > 7) return 0;
    }
    if (i >= n || s[i] != ';') return 0;
    append_utf8(out, value);  // 0, surrogates and out-of-range become U+FFFD
    return i + 1 - pos;
  }
  struct Named {
    std::string_view name;
    char ch;
  };
  static constexpr Named kNamed[] = {
      {"amp;", '&'}, {"lt;", '<'}, {"gt;", '>'}, {"quot;", '"'}};
  for (const Named& e : kNamed) {
    if (starts_with_at(s, i, e.name)) {
      out.push_back(e.ch);
      return 1 + e.name.size();
    }
  }
  return 0;
}

std::string decode_entities(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  std::size_t i = 0;
  while (i < s.size()) {
    const std::size_t amp = s.find('&', i);
    if (amp == std::string_view::npos) {
      out.append(s.substr(i));
      break;
    }
    out.append(s.substr(i, amp - i));
    const std::size_t used = match_entity(s, amp, out);
    if (used == 0) {
      out.push_back('&');
      i = amp + 1;
    } else {
      i = amp + used;
    }
  }
  return out;
}

std::string unescape_backslashes(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (std::size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '\\' && i + 1 < s.size() && is_ascii_punct(s[i + 1])) ++i;
    out.push_back(s[i]);
  }
  return out;
}

std::string_view rtrim(std::string_view s) noexcept {
  while (!s.empty() && is_space(s.back())) s.remove_suffix(1);
  return s;
}

std::string_view trim(std::string_view s) noexcept {
  s = rtrim(s);
  while (!s.empty() && is_space(s.front())) s.remove_prefix(1);
  return s;
}

}  // namespace commonmark::detail
