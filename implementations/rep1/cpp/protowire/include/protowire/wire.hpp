// Low-level wire-format primitives: varints, zigzag, a bounded byte reader.
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace protowire {

/// Number of bytes of the minimal varint encoding of `v`.
inline std::size_t varintSize(std::uint64_t v) {
  std::size_t n = 1;
  while (v >= 0x80) { v >>= 7; ++n; }
  return n;
}

/// Appends the minimal varint encoding of `v`.
inline void appendVarint(std::vector<std::uint8_t>& out, std::uint64_t v) {
  while (v >= 0x80) {
    out.push_back(static_cast<std::uint8_t>(v | 0x80));
    v >>= 7;
  }
  out.push_back(static_cast<std::uint8_t>(v));
}

inline std::uint32_t zigzag32(std::int32_t v) {
  return (static_cast<std::uint32_t>(v) << 1) ^ static_cast<std::uint32_t>(v >> 31);
}
inline std::uint64_t zigzag64(std::int64_t v) {
  return (static_cast<std::uint64_t>(v) << 1) ^ static_cast<std::uint64_t>(v >> 63);
}
inline std::int32_t unzigzag32(std::uint32_t u) {
  return static_cast<std::int32_t>((u >> 1) ^ (0u - (u & 1u)));
}
inline std::int64_t unzigzag64(std::uint64_t u) {
  return static_cast<std::int64_t>((u >> 1) ^ (0ull - (u & 1ull)));
}

/// Cursor over a byte range. Every read either succeeds and advances, or
/// returns false (truncated / over-long input) and leaves the cursor unspecified.
class Reader {
 public:
  Reader(const std::uint8_t* begin, const std::uint8_t* end) : p_(begin), end_(end) {}

  bool empty() const { return p_ == end_; }
  std::size_t remaining() const { return static_cast<std::size_t>(end_ - p_); }

  /// Reads a varint of at most `maxBytes` (<= 10) bytes. Bits beyond bit 63 are discarded.
  bool readVarint(std::size_t maxBytes, std::uint64_t& out) {
    std::uint64_t result = 0;
    for (std::size_t i = 0; i < maxBytes; ++i) {
      if (p_ == end_) return false;
      const std::uint8_t b = *p_++;
      result |= static_cast<std::uint64_t>(b & 0x7f) << (7 * i);
      if (!(b & 0x80)) { out = result; return true; }
    }
    return false;
  }

  bool readFixed32(std::uint32_t& out) {
    if (remaining() < 4) return false;
    out = 0;
    for (int i = 0; i < 4; ++i) out |= static_cast<std::uint32_t>(p_[i]) << (8 * i);
    p_ += 4;
    return true;
  }

  bool readFixed64(std::uint64_t& out) {
    if (remaining() < 8) return false;
    out = 0;
    for (int i = 0; i < 8; ++i) out |= static_cast<std::uint64_t>(p_[i]) << (8 * i);
    p_ += 8;
    return true;
  }

  /// Splits off the next `n` bytes as a sub-reader.
  bool take(std::size_t n, Reader& sub) {
    if (remaining() < n) return false;
    sub = Reader(p_, p_ + n);
    p_ += n;
    return true;
  }

  /// Pointer to the next unread byte.
  const std::uint8_t* data() const { return p_; }

 private:
  const std::uint8_t* p_;
  const std::uint8_t* end_;
};

}  // namespace protowire
