#include "mime/charset.hpp"

#include "mime/text.hpp"

namespace mime {
namespace {

enum class Table { Ascii, Utf8, Latin1, Cp1252 };

Table resolve(std::string_view name) {
  std::string n = normalize_charset_name(name);
  if (n == "us-ascii" || n == "ascii" || n == "iso-ir-6" || n == "ansi_x3.4-1968" ||
      n == "iso646-us")
    return Table::Ascii;
  if (n == "utf-8" || n == "utf8" || n == "unicode-1-1-utf-8") return Table::Utf8;
  if (n == "iso-8859-1" || n == "iso8859-1" || n == "latin-1" || n == "latin1" || n == "l1" ||
      n == "8859-1" || n == "iso_8859-1")
    return Table::Latin1;
  return Table::Cp1252;
}

constexpr char32_t kCp1252High[32] = {
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178};

}  // namespace

std::string normalize_charset_name(std::string_view name) {
  return ascii_lower(strip_blanks(name));
}

void append_utf8(std::string& out, char32_t cp) {
  if (cp < 0x80) {
    out += static_cast<char>(cp);
  } else if (cp < 0x800) {
    out += static_cast<char>(0xC0 | (cp >> 6));
    out += static_cast<char>(0x80 | (cp & 0x3F));
  } else if (cp < 0x10000) {
    out += static_cast<char>(0xE0 | (cp >> 12));
    out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
    out += static_cast<char>(0x80 | (cp & 0x3F));
  } else {
    out += static_cast<char>(0xF0 | (cp >> 18));
    out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
    out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
    out += static_cast<char>(0x80 | (cp & 0x3F));
  }
}

std::string decode_utf8(std::string_view bytes) {
  std::string out;
  out.reserve(bytes.size());
  const std::size_t n = bytes.size();
  std::size_t i = 0;
  while (i < n) {
    unsigned char b0 = static_cast<unsigned char>(bytes[i]);
    if (b0 < 0x80) {
      out += static_cast<char>(b0);
      ++i;
      continue;
    }
    int len = 0;
    unsigned char lo = 0x80, hi = 0xBF;
    if (b0 >= 0xC2 && b0 <= 0xDF) {
      len = 2;
    } else if (b0 == 0xE0) {
      len = 3; lo = 0xA0;
    } else if (b0 >= 0xE1 && b0 <= 0xEC) {
      len = 3;
    } else if (b0 == 0xED) {
      len = 3; hi = 0x9F;
    } else if (b0 == 0xEE || b0 == 0xEF) {
      len = 3;
    } else if (b0 == 0xF0) {
      len = 4; lo = 0x90;
    } else if (b0 >= 0xF1 && b0 <= 0xF3) {
      len = 4;
    } else if (b0 == 0xF4) {
      len = 4; hi = 0x8F;
    }
    if (len == 0) {
      append_utf8(out, 0xFFFD);
      ++i;
      continue;
    }
    char32_t cp = b0 & (0xFF >> (len + 1));
    int used = 1;
    bool ok = true;
    for (int k = 1; k < len; ++k) {
      if (i + k >= n) { ok = false; break; }
      unsigned char b = static_cast<unsigned char>(bytes[i + k]);
      unsigned char l = k == 1 ? lo : 0x80, h = k == 1 ? hi : 0xBF;
      if (b < l || b > h) { ok = false; break; }
      cp = (cp << 6) | (b & 0x3F);
      ++used;
    }
    if (ok) {
      append_utf8(out, cp);
    } else {
      append_utf8(out, 0xFFFD);
    }
    i += used;
  }
  return out;
}

std::string decode(std::string_view bytes, std::string_view charset) {
  switch (resolve(charset)) {
    case Table::Utf8:
      return decode_utf8(bytes);
    case Table::Ascii: {
      std::string out;
      out.reserve(bytes.size());
      for (char c : bytes) {
        if (static_cast<unsigned char>(c) < 0x80) out += c;
        else append_utf8(out, 0xFFFD);
      }
      return out;
    }
    case Table::Latin1: {
      std::string out;
      out.reserve(bytes.size() + bytes.size() / 4);
      for (char c : bytes) append_utf8(out, static_cast<unsigned char>(c));
      return out;
    }
    case Table::Cp1252:
      break;
  }
  std::string out;
  out.reserve(bytes.size() + bytes.size() / 4);
  for (char c : bytes) {
    unsigned char b = static_cast<unsigned char>(c);
    if (b >= 0x80 && b <= 0x9F) append_utf8(out, kCp1252High[b - 0x80]);
    else append_utf8(out, b);
  }
  return out;
}

std::size_t count_code_points(std::string_view utf8) {
  std::size_t n = 0;
  for (char c : utf8)
    if ((static_cast<unsigned char>(c) & 0xC0) != 0x80) ++n;
  return n;
}

}  // namespace mime
