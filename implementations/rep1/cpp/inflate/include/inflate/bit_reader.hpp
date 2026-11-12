#pragma once
/// \file bit_reader.hpp
/// LSB-first bit reader over an in-memory byte buffer.
///
/// Bits are delivered starting from the least significant bit of each byte,
/// as DEFLATE requires. The reader can *peek* past the end of the data (the
/// missing bits read as zero) but can never *consume* bits that do not exist.

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace inflate {

class BitReader {
 public:
  BitReader(const std::uint8_t* data, std::size_t size) noexcept
      : data_(data), size_(size) {}

  /// Top up the bit buffer to at least 57 bits, or as many as remain.
  void refill() noexcept {
    while (count_ <= 56 && pos_ < size_) {
      buf_ |= static_cast<std::uint64_t>(data_[pos_++]) << count_;
      count_ += 8;
    }
  }

  /// Bits currently buffered (call refill() first to maximise this).
  unsigned buffered() const noexcept { return count_; }

  /// The next `n` (<= 32) buffered bits without consuming them. Bits beyond
  /// the end of the stream read as zero.
  std::uint32_t peek(unsigned n) const noexcept {
    return static_cast<std::uint32_t>(buf_ & ((std::uint64_t{1} << n) - 1));
  }

  /// Discard `n` buffered bits. The caller guarantees n <= buffered().
  void drop(unsigned n) noexcept {
    buf_ >>= n;
    count_ -= n;
  }

  /// Read an `n`-bit (<= 32) value, first bit in the least significant
  /// position. Returns false, consuming nothing, if fewer than n bits remain.
  bool read(unsigned n, std::uint32_t& value) noexcept {
    if (count_ < n) {
      refill();
      if (count_ < n) return false;
    }
    value = peek(n);
    drop(n);
    return true;
  }

  /// Discard bits up to the next byte boundary (nothing if already aligned).
  void align_to_byte() noexcept { drop(count_ & 7); }

  /// Number of whole, unconsumed bytes left (including buffered ones). Any
  /// partial byte left over from earlier reads is not counted.
  std::size_t whole_bytes_remaining() const noexcept {
    return count_ / 8 + (size_ - pos_);
  }

  /// Copy `n` bytes to `dst`. Requires a byte-aligned position and
  /// n <= whole_bytes_remaining().
  void read_aligned_bytes(std::uint8_t* dst, std::size_t n) noexcept {
    while (n > 0 && count_ > 0) {
      *dst++ = static_cast<std::uint8_t>(buf_);
      drop(8);
      --n;
    }
    if (n > 0) {
      std::memcpy(dst, data_ + pos_, n);
      pos_ += n;
    }
  }

 private:
  const std::uint8_t* data_;
  std::size_t size_;
  std::size_t pos_ = 0;
  std::uint64_t buf_ = 0;
  unsigned count_ = 0;
};

}  // namespace inflate
