#include "fulltext/utf8.hpp"

namespace fulltext::utf8 {

namespace {
bool is_cont(std::string_view s, std::size_t i) noexcept {
  return i < s.size() && (static_cast<unsigned char>(s[i]) & 0xC0) == 0x80;
}
}  // namespace

Decoded decode(std::string_view s, std::size_t i) noexcept {
  const auto b0 = static_cast<unsigned char>(s[i]);
  if (b0 < 0x80) return {b0, 1};
  if (b0 >= 0xC2 && b0 <= 0xDF && is_cont(s, i + 1)) {
    return {static_cast<char32_t>(((b0 & 0x1F) << 6) | (s[i + 1] & 0x3F)), 2};
  }
  if (b0 >= 0xE0 && b0 <= 0xEF && is_cont(s, i + 1) && is_cont(s, i + 2)) {
    return {static_cast<char32_t>(((b0 & 0x0F) << 12) | ((s[i + 1] & 0x3F) << 6) |
                                  (s[i + 2] & 0x3F)),
            3};
  }
  if (b0 >= 0xF0 && b0 <= 0xF4 && is_cont(s, i + 1) && is_cont(s, i + 2) &&
      is_cont(s, i + 3)) {
    return {static_cast<char32_t>(((b0 & 0x07) << 18) | ((s[i + 1] & 0x3F) << 12) |
                                  ((s[i + 2] & 0x3F) << 6) | (s[i + 3] & 0x3F)),
            4};
  }
  return {0xFFFD, 1};
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

unsigned whitespace_length_at(std::string_view s, std::size_t i) noexcept {
  const auto b = static_cast<unsigned char>(s[i]);
  if ((b >= 0x09 && b <= 0x0D) || b == 0x20) return 1;
  if (b == 0xC2 && i + 1 < s.size() && static_cast<unsigned char>(s[i + 1]) == 0xA0) return 2;
  return 0;
}

std::string_view strip(std::string_view s) noexcept {
  std::size_t begin = 0;
  while (begin < s.size()) {
    const unsigned n = whitespace_length_at(s, begin);
    if (n == 0) break;
    begin += n;
  }
  std::size_t end = s.size();
  while (end > begin) {
    const auto b = static_cast<unsigned char>(s[end - 1]);
    if ((b >= 0x09 && b <= 0x0D) || b == 0x20) {
      --end;
    } else if (b == 0xA0 && end - 1 > begin && static_cast<unsigned char>(s[end - 2]) == 0xC2) {
      end -= 2;
    } else {
      break;
    }
  }
  return s.substr(begin, end - begin);
}

}  // namespace fulltext::utf8
