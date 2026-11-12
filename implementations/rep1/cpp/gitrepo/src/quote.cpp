#include "gitrepo/quote.hpp"

namespace gitrepo {

std::string quote_path(std::string_view name) {
  auto plain = [](unsigned char c) { return c >= 0x20 && c <= 0x7e && c != '"' && c != '\\'; };
  bool needs_quotes = false;
  for (char c : name) {
    if (!plain(static_cast<unsigned char>(c))) {
      needs_quotes = true;
      break;
    }
  }
  if (!needs_quotes) return std::string(name);

  std::string out = "\"";
  for (char ch : name) {
    unsigned char c = static_cast<unsigned char>(ch);
    switch (c) {
      case 0x07: out += "\\a"; break;
      case 0x08: out += "\\b"; break;
      case 0x09: out += "\\t"; break;
      case 0x0a: out += "\\n"; break;
      case 0x0b: out += "\\v"; break;
      case 0x0c: out += "\\f"; break;
      case 0x0d: out += "\\r"; break;
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      default:
        if (c < 0x20 || c >= 0x7f) {
          out += '\\';
          out += static_cast<char>('0' + (c >> 6));
          out += static_cast<char>('0' + ((c >> 3) & 7));
          out += static_cast<char>('0' + (c & 7));
        } else {
          out += ch;
        }
    }
  }
  out += '"';
  return out;
}

}  // namespace gitrepo
