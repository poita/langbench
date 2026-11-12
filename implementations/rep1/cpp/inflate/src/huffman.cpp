#include "inflate/huffman.hpp"

#include <algorithm>

namespace inflate {
namespace {

std::uint32_t reverse_bits(std::uint32_t code, unsigned len) {
  std::uint32_t r = 0;
  for (unsigned i = 0; i < len; ++i) {
    r = (r << 1) | (code & 1);
    code >>= 1;
  }
  return r;
}

}  // namespace

HuffmanInfo HuffmanTable::build(const std::uint8_t* lengths, std::size_t count) {
  HuffmanInfo info;
  std::uint32_t counts[kMaxCodeBits + 1] = {};
  for (std::size_t i = 0; i < count; ++i) ++counts[lengths[i]];
  info.used = static_cast<unsigned>(count - counts[0]);
  info.length_one = counts[1];

  // Kraft sum: `left` is the number of unassigned codes at the current length.
  std::int64_t left = 1;
  for (unsigned len = 1; len <= kMaxCodeBits; ++len) {
    left = (left << 1) - counts[len];
    if (left < 0) {
      info.kind = HuffmanInfo::Kind::OverSubscribed;
      table_.assign(std::size_t{1} << root_bits_, Entry{});
      return info;
    }
  }
  if (left > 0) info.kind = HuffmanInfo::Kind::Incomplete;

  const std::size_t root_size = std::size_t{1} << root_bits_;
  table_.assign(root_size, Entry{});

  std::uint32_t next_code[kMaxCodeBits + 2] = {};
  auto init_next_code = [&] {
    std::uint32_t code = 0;
    for (unsigned len = 1; len <= kMaxCodeBits; ++len) {
      code = (code + (len > 1 ? counts[len - 1] : 0)) << 1;
      next_code[len] = code;
    }
  };

  // Pass 1: size the second-level table needed behind each root prefix.
  bool any_long = false;
  if (info.used > 0) {
    sub_bits_.assign(root_size, 0);
    init_next_code();
    for (std::size_t sym = 0; sym < count; ++sym) {
      const unsigned len = lengths[sym];
      if (len == 0) continue;
      const std::uint32_t code = next_code[len]++;
      if (len > root_bits_) {
        const std::uint32_t prefix = reverse_bits(code, len) & (root_size - 1);
        sub_bits_[prefix] = std::max<std::uint8_t>(sub_bits_[prefix],
                                                   static_cast<std::uint8_t>(len - root_bits_));
        any_long = true;
      }
    }
  }
  if (any_long) {
    for (std::size_t prefix = 0; prefix < root_size; ++prefix) {
      if (sub_bits_[prefix] == 0) continue;
      Entry link;
      link.value = static_cast<std::uint16_t>(table_.size());
      link.bits = sub_bits_[prefix];
      link.kind = kLink;
      table_.resize(table_.size() + (std::size_t{1} << link.bits));
      table_[prefix] = link;
    }
  }

  // Pass 2: fill in the leaves. Stream codes are read MSB-first, so the table
  // is indexed by the bit-reversed code.
  init_next_code();
  for (std::size_t sym = 0; sym < count; ++sym) {
    const unsigned len = lengths[sym];
    if (len == 0) continue;
    const std::uint32_t rev = reverse_bits(next_code[len]++, len);
    Entry leaf;
    leaf.value = static_cast<std::uint16_t>(sym);
    leaf.bits = static_cast<std::uint8_t>(len);
    leaf.kind = kLeaf;
    if (len <= root_bits_) {
      for (std::size_t i = rev; i < root_size; i += std::size_t{1} << len) table_[i] = leaf;
    } else {
      const Entry& link = table_[rev & (root_size - 1)];
      const std::size_t sub_size = std::size_t{1} << link.bits;
      for (std::size_t i = rev >> root_bits_; i < sub_size;
           i += std::size_t{1} << (len - root_bits_)) {
        table_[link.value + i] = leaf;
      }
    }
  }
  return info;
}

}  // namespace inflate
