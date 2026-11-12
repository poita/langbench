// Entity decoding, backslash handling and HTML/URL escaping.
#include "common.hpp"

#include <cstring>

#include "sitegen/text.hpp"

namespace sitegen::md_detail {

namespace {

int hex_value(unsigned char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

bool starts_with_at(std::string_view s, std::size_t i, std::string_view prefix) {
  return s.size() - i >= prefix.size() && s.compare(i, prefix.size(), prefix) == 0;
}

}  // namespace

std::size_t decode_entity_at(std::string_view s, std::size_t i, std::string& out) {
  if (i >= s.size()) return 0;
  if (s[i] == '#') {
    std::size_t j = i + 1;
    bool hex = false;
    if (j < s.size() && (s[j] == 'x' || s[j] == 'X')) {
      hex = true;
      ++j;
    }
    const std::size_t max_digits = hex ? 6 : 7;
    const std::size_t start = j;
    std::uint32_t value = 0;
    while (j < s.size() && j - start < max_digits) {
      const int d = hex ? hex_value(static_cast<unsigned char>(s[j]))
                        : (is_digit(static_cast<unsigned char>(s[j])) ? s[j] - '0' : -1);
      if (d < 0) break;
      value = value * (hex ? 16u : 10u) + static_cast<std::uint32_t>(d);
      ++j;
    }
    if (j == start || j >= s.size() || s[j] != ';') return 0;
    if (value == 0 || (value >= 0xD800 && value <= 0xDFFF) || value > 0x10FFFF) value = 0xFFFD;
    text::append_utf8(out, static_cast<char32_t>(value));
    return j + 1 - i;
  }
  struct Named {
    std::string_view name;
    char ch;
  };
  static constexpr Named kNamed[] = {{"amp;", '&'}, {"lt;", '<'}, {"gt;", '>'}, {"quot;", '"'}};
  for (const Named& n : kNamed) {
    if (starts_with_at(s, i, n.name)) {
      out.push_back(n.ch);
      return n.name.size();
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
    const std::size_t used = decode_entity_at(s, amp + 1, out);
    if (used == 0) {
      out.push_back('&');
      i = amp + 1;
    } else {
      i = amp + 1 + used;
    }
  }
  return out;
}

std::string unescape_backslashes(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (std::size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '\\' && i + 1 < s.size() && is_ascii_punct(static_cast<unsigned char>(s[i + 1]))) {
      ++i;
    }
    out.push_back(s[i]);
  }
  return out;
}

void escape_html(std::string& out, std::string_view s) {
  std::size_t run = 0;
  for (std::size_t i = 0; i < s.size(); ++i) {
    const char* repl = nullptr;
    switch (s[i]) {
      case '&': repl = "&amp;"; break;
      case '<': repl = "&lt;"; break;
      case '>': repl = "&gt;"; break;
      case '"': repl = "&quot;"; break;
      default: break;
    }
    if (repl != nullptr) {
      out.append(s.data() + run, i - run);
      out.append(repl);
      run = i + 1;
    }
  }
  out.append(s.data() + run, s.size() - run);
}

void escape_href(std::string& out, std::string_view s) {
  static const char kHex[] = "0123456789ABCDEF";
  static const char kSafe[] = "-_.~!#$%()*+,/:;=?@";
  for (const char ch : s) {
    const unsigned char c = static_cast<unsigned char>(ch);
    if (is_alnum(c) || (c != 0 && std::strchr(kSafe, c) != nullptr)) {
      out.push_back(ch);
    } else if (c == '&') {
      out.append("&amp;");
    } else if (c == '\'') {
      out.append("&#x27;");
    } else {
      out.push_back('%');
      out.push_back(kHex[c >> 4]);
      out.push_back(kHex[c & 15]);
    }
  }
}

bool is_dangerous_url(std::string_view url) {
  auto starts_ci = [&](std::string_view prefix) {
    if (url.size() < prefix.size()) return false;
    for (std::size_t i = 0; i < prefix.size(); ++i) {
      char c = url[i];
      if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
      if (c != prefix[i]) return false;
    }
    return true;
  };
  if (!(starts_ci("javascript:") || starts_ci("vbscript:") || starts_ci("file:") ||
        starts_ci("data:"))) {
    return false;
  }
  return !(starts_ci("data:image/png") || starts_ci("data:image/gif") ||
           starts_ci("data:image/jpeg") || starts_ci("data:image/webp"));
}

}  // namespace sitegen::md_detail
