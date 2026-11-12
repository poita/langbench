#include "webhooks/sha256.hpp"

#include <algorithm>
#include <cstring>

namespace webhooks {

namespace {

constexpr std::array<std::uint32_t, 8> kInitialState = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};

constexpr std::array<std::uint32_t, 64> kRoundConstants = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

constexpr std::uint32_t ror(std::uint32_t x, unsigned n) noexcept {
  return (x >> n) | (x << (32 - n));
}

}  // namespace

void Sha256::reset() noexcept {
  state_ = kInitialState;
  buffered_ = 0;
  length_ = 0;
}

void Sha256::compress(const std::uint8_t* block) noexcept {
  std::uint32_t w[64];
  for (int t = 0; t < 16; ++t) {
    w[t] = std::uint32_t(block[4 * t]) << 24 | std::uint32_t(block[4 * t + 1]) << 16 |
           std::uint32_t(block[4 * t + 2]) << 8 | std::uint32_t(block[4 * t + 3]);
  }
  for (int t = 16; t < 64; ++t) {
    std::uint32_t s0 = ror(w[t - 15], 7) ^ ror(w[t - 15], 18) ^ (w[t - 15] >> 3);
    std::uint32_t s1 = ror(w[t - 2], 17) ^ ror(w[t - 2], 19) ^ (w[t - 2] >> 10);
    w[t] = w[t - 16] + s0 + w[t - 7] + s1;
  }
  std::uint32_t a = state_[0], b = state_[1], c = state_[2], d = state_[3];
  std::uint32_t e = state_[4], f = state_[5], g = state_[6], h = state_[7];
  for (int t = 0; t < 64; ++t) {
    std::uint32_t big_s1 = ror(e, 6) ^ ror(e, 11) ^ ror(e, 25);
    std::uint32_t ch = (e & f) ^ (~e & g);
    std::uint32_t temp1 = h + big_s1 + ch + kRoundConstants[t] + w[t];
    std::uint32_t big_s0 = ror(a, 2) ^ ror(a, 13) ^ ror(a, 22);
    std::uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
    std::uint32_t temp2 = big_s0 + maj;
    h = g;
    g = f;
    f = e;
    e = d + temp1;
    d = c;
    c = b;
    b = a;
    a = temp1 + temp2;
  }
  state_[0] += a;
  state_[1] += b;
  state_[2] += c;
  state_[3] += d;
  state_[4] += e;
  state_[5] += f;
  state_[6] += g;
  state_[7] += h;
}

Sha256& Sha256::update(ByteView data) noexcept {
  length_ += data.size();
  const std::uint8_t* p = data.data();
  std::size_t n = data.size();
  if (buffered_ > 0) {
    std::size_t take = std::min(n, kBlockSize - buffered_);
    std::memcpy(buffer_.data() + buffered_, p, take);
    buffered_ += take;
    p += take;
    n -= take;
    if (buffered_ < kBlockSize) return *this;
    compress(buffer_.data());
    buffered_ = 0;
  }
  while (n >= kBlockSize) {
    compress(p);
    p += kBlockSize;
    n -= kBlockSize;
  }
  if (n > 0) {
    std::memcpy(buffer_.data(), p, n);
    buffered_ = n;
  }
  return *this;
}

Sha256::Digest Sha256::finish() noexcept {
  const std::uint64_t bit_length = length_ * 8;
  buffer_[buffered_++] = 0x80;
  if (buffered_ > 56) {
    std::fill(buffer_.begin() + buffered_, buffer_.end(), 0);
    compress(buffer_.data());
    buffered_ = 0;
  }
  std::fill(buffer_.begin() + buffered_, buffer_.begin() + 56, 0);
  for (int i = 0; i < 8; ++i) {
    buffer_[56 + i] = static_cast<std::uint8_t>(bit_length >> (56 - 8 * i));
  }
  compress(buffer_.data());
  buffered_ = 0;

  Digest out;
  for (int i = 0; i < 8; ++i) {
    out[4 * i] = static_cast<std::uint8_t>(state_[i] >> 24);
    out[4 * i + 1] = static_cast<std::uint8_t>(state_[i] >> 16);
    out[4 * i + 2] = static_cast<std::uint8_t>(state_[i] >> 8);
    out[4 * i + 3] = static_cast<std::uint8_t>(state_[i]);
  }
  return out;
}

Sha256::Digest sha256(ByteView data) noexcept {
  Sha256 h;
  h.update(data);
  return h.finish();
}

}  // namespace webhooks
