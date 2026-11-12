#include "webhooks/base64.hpp"

#include <array>

namespace webhooks {

namespace {

constexpr char kStandard[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
constexpr char kUrlSafe[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

std::string encode(ByteView data, const char* alphabet, bool pad) {
  std::string out;
  out.reserve((data.size() + 2) / 3 * 4);
  std::size_t i = 0;
  for (; i + 3 <= data.size(); i += 3) {
    std::uint32_t v = std::uint32_t(data[i]) << 16 | std::uint32_t(data[i + 1]) << 8 | data[i + 2];
    out.push_back(alphabet[v >> 18 & 63]);
    out.push_back(alphabet[v >> 12 & 63]);
    out.push_back(alphabet[v >> 6 & 63]);
    out.push_back(alphabet[v & 63]);
  }
  std::size_t rest = data.size() - i;
  if (rest == 1) {
    std::uint32_t v = std::uint32_t(data[i]) << 16;
    out.push_back(alphabet[v >> 18 & 63]);
    out.push_back(alphabet[v >> 12 & 63]);
    if (pad) out.append("==");
  } else if (rest == 2) {
    std::uint32_t v = std::uint32_t(data[i]) << 16 | std::uint32_t(data[i + 1]) << 8;
    out.push_back(alphabet[v >> 18 & 63]);
    out.push_back(alphabet[v >> 12 & 63]);
    out.push_back(alphabet[v >> 6 & 63]);
    if (pad) out.push_back('=');
  }
  return out;
}

// Value of each byte in either alphabet; -1 if in neither. '+' '/' map to 62 63
// and '-' '_' also map to 62 63; mixing is detected separately.
constexpr std::array<std::int8_t, 256> make_table() {
  std::array<std::int8_t, 256> t{};
  for (auto& v : t) v = -1;
  for (int i = 0; i < 64; ++i) {
    t[static_cast<unsigned char>(kStandard[i])] = static_cast<std::int8_t>(i);
    t[static_cast<unsigned char>(kUrlSafe[i])] = static_cast<std::int8_t>(i);
  }
  return t;
}
constexpr auto kDecodeTable = make_table();

}  // namespace

std::string base64_encode(ByteView data) { return encode(data, kStandard, true); }

std::string base64url_encode(ByteView data) { return encode(data, kUrlSafe, false); }

std::optional<Bytes> base64_decode(std::string_view text) {
  std::size_t body_len = text.size();
  while (body_len > 0 && text[body_len - 1] == '=') --body_len;
  const std::size_t pad = text.size() - body_len;
  std::string_view body = text.substr(0, body_len);

  bool has_standard = false, has_url = false;
  for (char c : body) {
    if (kDecodeTable[static_cast<unsigned char>(c)] < 0) return std::nullopt;  // includes '='
    if (c == '+' || c == '/') has_standard = true;
    if (c == '-' || c == '_') has_url = true;
  }
  if (has_standard && has_url) return std::nullopt;

  const std::size_t rem = body.size() % 4;
  if (rem == 1) return std::nullopt;
  if (pad > 0) {
    if (rem == 0 || pad != 4 - rem) return std::nullopt;
  }

  Bytes out;
  out.reserve(body.size() * 6 / 8);
  std::uint32_t acc = 0;
  int bits = 0;
  for (char c : body) {
    acc = acc << 6 | static_cast<std::uint32_t>(kDecodeTable[static_cast<unsigned char>(c)]);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back(static_cast<std::uint8_t>(acc >> bits));
      acc &= (1u << bits) - 1;
    }
  }
  return out;
}

}  // namespace webhooks
