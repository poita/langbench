#include "mime/text.hpp"

namespace mime {

std::string_view strip_blanks(std::string_view s) {
  while (!s.empty() && is_blank(s.front())) s.remove_prefix(1);
  while (!s.empty() && is_blank(s.back())) s.remove_suffix(1);
  return s;
}

std::string ascii_lower(std::string_view s) {
  std::string out(s);
  for (char& c : out)
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + ('a' - 'A'));
  return out;
}

std::string collapse(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  bool in_run = false;
  for (char c : s) {
    if (is_blank(c)) {
      in_run = true;
    } else {
      if (in_run && !out.empty()) out += ' ';
      in_run = false;
      out += c;
    }
  }
  // A trailing run is dropped; a leading run never emitted a space.
  return out;
}

std::string normalize_newlines(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (std::size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '\r' && i + 1 < s.size() && s[i + 1] == '\n') continue;
    out += s[i];
  }
  return out;
}

std::vector<std::string_view> split_lines(std::string_view s) {
  std::vector<std::string_view> lines;
  std::size_t pos = 0;
  while (pos < s.size()) {
    std::size_t nl = s.find('\n', pos);
    std::size_t end = nl == std::string_view::npos ? s.size() : nl;
    std::size_t next = nl == std::string_view::npos ? s.size() : nl + 1;
    std::string_view line = s.substr(pos, end - pos);
    if (nl != std::string_view::npos && !line.empty() && line.back() == '\r')
      line.remove_suffix(1);
    lines.push_back(line);
    pos = next;
  }
  return lines;
}

QuotedString scan_quoted(std::string_view s, std::size_t pos) {
  QuotedString q;
  std::size_t i = pos + 1;
  while (i < s.size()) {
    char c = s[i];
    if (c == '\\') {
      if (i + 1 < s.size()) {
        q.text += s[i + 1];
        i += 2;
      } else {
        q.text += '\\';
        ++i;
      }
    } else if (c == '"') {
      q.end = i + 1;
      return q;
    } else {
      q.text += c;
      ++i;
    }
  }
  q.end = s.size();
  return q;
}

std::size_t skip_comment(std::string_view s, std::size_t pos) {
  int depth = 1;
  std::size_t i = pos + 1;
  while (i < s.size()) {
    char c = s[i];
    if (c == '\\') {
      i += 2;
      continue;
    }
    if (c == '(') {
      ++depth;
    } else if (c == ')') {
      if (--depth == 0) return i + 1;
    }
    ++i;
  }
  return s.size();
}

std::string escape(std::string_view s) {
  static const char* hex = "0123456789abcdef";
  std::string out;
  out.reserve(s.size() + 8);
  auto put_hex = [&](unsigned v) {
    out += "\\x";
    out += hex[(v >> 4) & 15];
    out += hex[v & 15];
  };
  for (std::size_t i = 0; i < s.size(); ++i) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    switch (c) {
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      case '"': out += "\\\""; break;
      default:
        if (c < 0x20 || c == 0x7F) {
          put_hex(c);
        } else if (c == 0xC2 && i + 1 < s.size() &&
                   static_cast<unsigned char>(s[i + 1]) >= 0x80 &&
                   static_cast<unsigned char>(s[i + 1]) <= 0x9F) {
          put_hex(static_cast<unsigned char>(s[i + 1]));  // C1 control U+0080..U+009F
          ++i;
        } else {
          out += s[i];
        }
    }
  }
  return out;
}

std::string quote(std::string_view s) { return "\"" + escape(s) + "\""; }

}  // namespace mime
