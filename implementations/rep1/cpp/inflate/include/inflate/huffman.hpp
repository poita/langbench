#pragma once
/// \file huffman.hpp
/// Table-driven canonical Huffman decoder.
///
/// A HuffmanTable is a two-level lookup table. The root table is indexed by
/// the next `root_bits` stream bits; codes longer than that continue in a
/// small second-level table reached through a link entry. Decoding a symbol
/// therefore costs one or two lookups, and building a table costs
/// O(n_symbols + 2^root_bits).

#include <cstddef>
#include <cstdint>
#include <vector>

#include "inflate/bit_reader.hpp"
#include "inflate/tables.hpp"

namespace inflate {

/// Result of HuffmanTable::build().
struct HuffmanInfo {
  enum class Kind { Complete, Incomplete, OverSubscribed };
  Kind kind = Kind::Complete;   ///< Kraft-sum classification of the length set.
  unsigned used = 0;            ///< Number of symbols with nonzero length.
  unsigned length_one = 0;      ///< Number of symbols with length 1.
  /// True for the one incomplete shape DEFLATE tolerates: a lone 1-bit code.
  bool single_one_bit_code() const { return used == 1 && length_one == 1; }
};

class HuffmanTable {
 public:
  /// Decode failure markers returned by decode() (all negative).
  static constexpr int kTruncated = -1;  ///< Code extends past end of stream.
  static constexpr int kInvalid = -2;    ///< Bit pattern is not a code.

  /// `root_bits` is the width of the first-level index (1..15).
  explicit HuffmanTable(unsigned root_bits) : root_bits_(root_bits) {}

  /// Build the table from code lengths (each 0..15; 0 = unused symbol) using
  /// canonical code assignment. An over-subscribed set leaves the table
  /// empty; an incomplete set yields a table in which unassigned bit
  /// patterns decode as kInvalid. The caller decides whether the returned
  /// classification is acceptable.
  HuffmanInfo build(const std::uint8_t* lengths, std::size_t count);

  /// Decode one symbol, consuming its code. Returns the symbol (>= 0),
  /// kTruncated or kInvalid; on failure no bits are consumed.
  int decode(BitReader& br) const noexcept {
    if (br.buffered() < kMaxCodeBits) br.refill();
    const std::uint32_t bits = br.peek(kMaxCodeBits);
    Entry e = table_[bits & root_mask()];
    if (e.kind == kLink) {
      e = table_[e.value + ((bits >> root_bits_) & ((1u << e.bits) - 1))];
    }
    if (e.kind != kLeaf) return kInvalid;
    if (e.bits > br.buffered()) return kTruncated;
    br.drop(e.bits);
    return e.value;
  }

 private:
  enum : std::uint8_t { kInvalidEntry = 0, kLeaf = 1, kLink = 2 };
  struct Entry {
    std::uint16_t value = 0;  // leaf: symbol; link: offset of the sub-table
    std::uint8_t bits = 0;    // leaf: full code length; link: sub-table index width
    std::uint8_t kind = kInvalidEntry;
  };

  std::uint32_t root_mask() const noexcept { return (1u << root_bits_) - 1; }

  unsigned root_bits_;
  std::vector<Entry> table_;
  std::vector<std::uint8_t> sub_bits_;  // scratch, one slot per root entry
};

}  // namespace inflate
