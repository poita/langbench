#pragma once
/// \file charset.hpp
/// A set of byte values, stored as a 256-bit bitmap.

#include <array>
#include <cstdint>

namespace regex {

class CharSet {
 public:
  constexpr CharSet() = default;

  /// Set containing exactly one byte.
  static CharSet single(unsigned char c);
  /// Set containing every byte value 0..255.
  static CharSet all();

  void add(unsigned char c) { w_[c >> 6] |= std::uint64_t{1} << (c & 63); }
  /// Adds every byte in [lo, hi] (inclusive).
  void add_range(unsigned char lo, unsigned char hi);
  /// Adds all members of \p other.
  void add_all(const CharSet& other);
  /// Replaces the set by its complement over 0..255.
  void invert();
  /// Replaces the set by its complement over ASCII (0..127) only.
  void invert_ascii();

  bool contains(unsigned char c) const {
    return (w_[c >> 6] >> (c & 63)) & 1;
  }
  bool empty() const { return !(w_[0] | w_[1] | w_[2] | w_[3]); }
  bool operator==(const CharSet& o) const { return w_ == o.w_; }

  /// `\d`, `\w`, `\s` (not complemented).
  static CharSet digits();
  static CharSet word();
  static CharSet space();

 private:
  std::array<std::uint64_t, 4> w_{};
};

}  // namespace regex
