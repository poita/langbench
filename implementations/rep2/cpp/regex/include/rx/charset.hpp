// A set of 8-bit characters, stored as a 256-bit bitmap.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace rx {

class CharSet {
 public:
  CharSet() = default;

  void add(unsigned char c) { w_[c >> 6] |= std::uint64_t{1} << (c & 63); }

  /// Adds every character in [lo, hi] (inclusive).
  void add_range(unsigned char lo, unsigned char hi) {
    for (unsigned c = lo; c <= hi; ++c) add(static_cast<unsigned char>(c));
  }

  void add_all(const CharSet& other) {
    for (std::size_t i = 0; i < w_.size(); ++i) w_[i] |= other.w_[i];
  }

  /// Replaces the set by its complement over all 256 byte values.
  void invert() {
    for (auto& w : w_) w = ~w;
  }

  bool contains(unsigned char c) const { return (w_[c >> 6] >> (c & 63)) & 1; }

  bool empty() const { return !(w_[0] | w_[1] | w_[2] | w_[3]); }

  /// Number of characters in the set.
  std::size_t size() const;

  /// \d : [0-9]
  static CharSet digits();
  /// \w : [A-Za-z0-9_]
  static CharSet word();
  /// \s : space, \t, \n, \r, \f, \v
  static CharSet space();

  bool operator==(const CharSet& o) const { return w_ == o.w_; }

 private:
  std::array<std::uint64_t, 4> w_{};
};

}  // namespace rx
