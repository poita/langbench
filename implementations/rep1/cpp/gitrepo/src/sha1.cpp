#include "gitrepo/sha1.hpp"

#include <algorithm>
#include <cstring>

namespace gitrepo {

namespace {
inline std::uint32_t rotl(std::uint32_t x, int n) {
  return (x << n) | (x >> (32 - n));
}
}  // namespace

Sha1::Sha1()
    : state_{0x67452301u, 0xefcdab89u, 0x98badcfeu, 0x10325476u, 0xc3d2e1f0u},
      buffer_{} {}

void Sha1::process_block(const std::uint8_t* p) {
  std::uint32_t w[80];
  for (int i = 0; i < 16; ++i) {
    w[i] = (std::uint32_t(p[4 * i]) << 24) | (std::uint32_t(p[4 * i + 1]) << 16) |
           (std::uint32_t(p[4 * i + 2]) << 8) | std::uint32_t(p[4 * i + 3]);
  }
  for (int i = 16; i < 80; ++i) {
    w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
  }
  std::uint32_t a = state_[0], b = state_[1], c = state_[2], d = state_[3],
                e = state_[4];
  for (int i = 0; i < 80; ++i) {
    std::uint32_t f, k;
    if (i < 20) {
      f = (b & c) | (~b & d);
      k = 0x5a827999u;
    } else if (i < 40) {
      f = b ^ c ^ d;
      k = 0x6ed9eba1u;
    } else if (i < 60) {
      f = (b & c) | (b & d) | (c & d);
      k = 0x8f1bbcdcu;
    } else {
      f = b ^ c ^ d;
      k = 0xca62c1d6u;
    }
    std::uint32_t t = rotl(a, 5) + f + e + k + w[i];
    e = d;
    d = c;
    c = rotl(b, 30);
    b = a;
    a = t;
  }
  state_[0] += a;
  state_[1] += b;
  state_[2] += c;
  state_[3] += d;
  state_[4] += e;
}

void Sha1::update(const void* data, std::size_t size) {
  const auto* p = static_cast<const std::uint8_t*>(data);
  total_ += size;
  if (buffered_ > 0) {
    std::size_t take = std::min(size, buffer_.size() - buffered_);
    std::memcpy(buffer_.data() + buffered_, p, take);
    buffered_ += take;
    p += take;
    size -= take;
    if (buffered_ == buffer_.size()) {
      process_block(buffer_.data());
      buffered_ = 0;
    }
  }
  while (size >= 64) {
    process_block(p);
    p += 64;
    size -= 64;
  }
  if (size > 0) {
    std::memcpy(buffer_.data(), p, size);
    buffered_ = size;
  }
}

ObjectId Sha1::finish() {
  std::uint64_t bit_length = total_ * 8;
  std::uint8_t pad[72] = {0x80};
  std::size_t pad_len = (buffered_ < 56) ? (56 - buffered_) : (120 - buffered_);
  for (int i = 0; i < 8; ++i) {
    pad[pad_len + i] = static_cast<std::uint8_t>(bit_length >> (56 - 8 * i));
  }
  update(pad, pad_len + 8);

  ObjectId id;
  for (int i = 0; i < 5; ++i) {
    id.bytes[4 * i] = static_cast<std::uint8_t>(state_[i] >> 24);
    id.bytes[4 * i + 1] = static_cast<std::uint8_t>(state_[i] >> 16);
    id.bytes[4 * i + 2] = static_cast<std::uint8_t>(state_[i] >> 8);
    id.bytes[4 * i + 3] = static_cast<std::uint8_t>(state_[i]);
  }
  return id;
}

ObjectId sha1(std::string_view data) {
  Sha1 h;
  h.update(data);
  return h.finish();
}

}  // namespace gitrepo
