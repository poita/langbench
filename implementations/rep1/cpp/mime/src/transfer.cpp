#include "mime/transfer.hpp"

namespace mime {
namespace {

int hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

int base64_value(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

}  // namespace

std::string decode_quoted_printable(std::string_view in) {
  std::string out;
  out.reserve(in.size());
  const std::size_t n = in.size();
  for (std::size_t i = 0; i < n;) {
    char c = in[i];
    if (c != '=') {
      out += c;
      ++i;
      continue;
    }
    if (i + 1 < n && in[i + 1] == '\n') {
      i += 2;
    } else if (i + 2 < n && hex_value(in[i + 1]) >= 0 && hex_value(in[i + 2]) >= 0) {
      out += static_cast<char>(hex_value(in[i + 1]) * 16 + hex_value(in[i + 2]));
      i += 3;
    } else if (i + 1 == n) {
      ++i;
    } else {
      out += '=';
      ++i;
    }
  }
  return out;
}

std::string decode_base64(std::string_view in) {
  std::string out;
  out.reserve(in.size() / 4 * 3 + 3);
  unsigned acc = 0;
  int count = 0;
  for (char c : in) {
    int v = base64_value(c);
    if (v < 0) continue;
    acc = (acc << 6) | static_cast<unsigned>(v);
    if (++count == 4) {
      out += static_cast<char>((acc >> 16) & 0xFF);
      out += static_cast<char>((acc >> 8) & 0xFF);
      out += static_cast<char>(acc & 0xFF);
      acc = 0;
      count = 0;
    }
  }
  if (count == 2) {
    out += static_cast<char>((acc >> 4) & 0xFF);
  } else if (count == 3) {
    out += static_cast<char>((acc >> 10) & 0xFF);
    out += static_cast<char>((acc >> 2) & 0xFF);
  }
  return out;
}

bool is_identity_encoding(std::string_view encoding) {
  return encoding != "quoted-printable" && encoding != "base64";
}

std::string decode_body(std::string_view body, std::string_view encoding) {
  if (encoding == "quoted-printable") return decode_quoted_printable(body);
  if (encoding == "base64") return decode_base64(body);
  return std::string(body);
}

}  // namespace mime
