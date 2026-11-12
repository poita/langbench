#pragma once
// Helpers for hand-building DEFLATE streams in tests.

#include <gtest/gtest.h>

#include <cstdint>
#include <string>
#include <vector>

#include "inflate/hex.hpp"
#include "inflate/inflate.hpp"
#include "inflate/tables.hpp"

namespace testing_support {

using Bytes = std::vector<std::uint8_t>;

inline Bytes from_hex(const std::string& h) {
  Bytes b;
  EXPECT_TRUE(inflate::hex_decode(h, b));
  return b;
}

inline Bytes bytes_of(const std::string& s) { return Bytes(s.begin(), s.end()); }

/// Writes bits LSB-first, as DEFLATE does.
class BitWriter {
 public:
  /// Numeric field: first bit written is bit 0 of `value`.
  void bits(std::uint32_t value, unsigned n) {
    for (unsigned i = 0; i < n; ++i) bit((value >> i) & 1);
  }
  /// Huffman code: first bit written is the most significant bit of `code`.
  void code(std::uint32_t code, unsigned n) {
    for (unsigned i = n; i-- > 0;) bit((code >> i) & 1);
  }
  void bit(unsigned b) {
    if (nbits_ % 8 == 0) bytes_.push_back(0);
    bytes_.back() |= static_cast<std::uint8_t>(b << (nbits_ % 8));
    ++nbits_;
  }
  void align() { nbits_ = (nbits_ + 7) & ~std::size_t{7}; }
  void raw_byte(std::uint8_t b) { bits(b, 8); }
  const Bytes& bytes() const { return bytes_; }

 private:
  Bytes bytes_;
  std::size_t nbits_ = 0;
};

/// Canonical code values for a set of lengths (RFC 1951 section 3.2.2).
inline std::vector<std::uint32_t> canonical_codes(const std::vector<unsigned>& lengths) {
  unsigned count[16] = {};
  for (unsigned l : lengths) ++count[l];
  count[0] = 0;
  std::uint32_t next[16] = {};
  std::uint32_t code = 0;
  for (unsigned l = 1; l < 16; ++l) {
    code = (code + count[l - 1]) << 1;
    next[l] = code;
  }
  std::vector<std::uint32_t> codes(lengths.size());
  for (std::size_t s = 0; s < lengths.size(); ++s)
    if (lengths[s]) codes[s] = next[lengths[s]]++;
  return codes;
}

inline void stored_block(BitWriter& w, const Bytes& data, bool final) {
  w.bits(final, 1);
  w.bits(0, 2);
  w.align();
  w.bits(static_cast<std::uint32_t>(data.size()), 16);
  w.bits(static_cast<std::uint32_t>(~data.size()) & 0xFFFF, 16);
  for (auto b : data) w.raw_byte(b);
}

/// A Huffman code (lengths + codes) that can emit symbols.
struct Code {
  std::vector<unsigned> lengths;
  std::vector<std::uint32_t> codes;
  explicit Code(std::vector<unsigned> l) : lengths(std::move(l)), codes(canonical_codes(lengths)) {}
  void put(BitWriter& w, unsigned sym) const { w.code(codes[sym], lengths[sym]); }
};

inline Code fixed_lit_code() {
  std::vector<unsigned> l(288);
  for (unsigned i = 0; i < 288; ++i) l[i] = i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8;
  return Code(l);
}
inline Code fixed_dist_code() { return Code(std::vector<unsigned>(32, 5)); }

/// Emit a literal/length symbol's extra bits and (optionally) a distance.
inline void put_match(BitWriter& w, const Code& lit, const Code& dist, unsigned length,
                      unsigned distance) {
  unsigned ls = 28;
  while (inflate::kLengthBase[ls] > length) --ls;
  // Prefer symbol 285 for 258, as encoders do.
  lit.put(w, 257 + ls);
  w.bits(length - inflate::kLengthBase[ls], inflate::kLengthExtra[ls]);
  unsigned ds = 29;
  while (inflate::kDistBase[ds] > distance) --ds;
  dist.put(w, ds);
  w.bits(distance - inflate::kDistBase[ds], inflate::kDistExtra[ds]);
}

/// Emits a dynamic block header whose lengths are described as code-length
/// tokens: {symbol, extra value}. `cl_lengths` are the 19 code-length code
/// lengths in symbol order; `hclen_count` how many (>= 4) are transmitted.
struct ClToken {
  unsigned sym;
  unsigned extra;
};
inline void dynamic_header(BitWriter& w, bool final, unsigned hlit, unsigned hdist,
                           const std::vector<unsigned>& cl_lengths, const std::vector<ClToken>& tokens,
                           unsigned hclen_count = 19) {
  w.bits(final, 1);
  w.bits(2, 2);
  w.bits(hlit, 5);
  w.bits(hdist, 5);
  w.bits(hclen_count - 4, 4);
  for (unsigned i = 0; i < hclen_count; ++i) w.bits(cl_lengths[inflate::kCodeLengthOrder[i]], 3);
  Code cl(cl_lengths);
  for (const auto& t : tokens) {
    cl.put(w, t.sym);
    if (t.sym == 16) w.bits(t.extra, 2);
    if (t.sym == 17) w.bits(t.extra, 3);
    if (t.sym == 18) w.bits(t.extra, 7);
  }
}

/// A code-length code giving every symbol 0..15 four bits (complete).
inline std::vector<unsigned> flat_cl_lengths() {
  std::vector<unsigned> l(19, 0);
  for (unsigned i = 0; i < 16; ++i) l[i] = 4;
  return l;
}

/// Tokens spelling out `lengths` literally (each must be <= 15).
inline std::vector<ClToken> literal_tokens(const std::vector<unsigned>& lengths) {
  std::vector<ClToken> t;
  for (unsigned l : lengths) t.push_back({l, 0});
  return t;
}

inline std::vector<unsigned> concat(std::vector<unsigned> a, const std::vector<unsigned>& b) {
  a.insert(a.end(), b.begin(), b.end());
  return a;
}

/// A tiny complete literal/length code: 'a' -> 1 bit, 'b' -> 2 bits,
/// end-of-block -> 2 bits. Returns 257 lengths (so HLIT = 0).
inline std::vector<unsigned> abc_lit_lengths() {
  std::vector<unsigned> l(257, 0);
  l[97] = 1;
  l[98] = 2;
  l[256] = 2;
  return l;
}

}  // namespace testing_support
