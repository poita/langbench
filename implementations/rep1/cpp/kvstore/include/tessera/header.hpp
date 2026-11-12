#pragma once
/// \file header.hpp
/// The header page (page 1) and the index directory (spec sections 7 and 8).

#include <array>
#include <cstdint>
#include <string>

#include "tessera/limits.hpp"
#include "tessera/page.hpp"

namespace tessera {

/// One slot of the index directory.
struct IndexSlot {
  bool live = false;
  std::string path;  ///< path text, 1..30 bytes when live
  std::uint32_t root = 0;
  std::uint32_t entries = 0;
};

/// The engine's header fields. These *are* the contents of page 1.
struct Header {
  std::uint32_t page_count = 1;
  std::uint32_t freelist_head = 0;
  std::uint32_t freelist_count = 0;
  std::uint32_t primary_root = 0;
  std::uint32_t primary_count = 0;
  std::uint64_t commit_counter = 0;
  std::array<IndexSlot, kMaxIndexes> slots;

  /// Number of live index slots.
  std::uint32_t index_count() const;
  /// Page 1 as 1024 canonical bytes.
  Page encode() const;
  /// Reads the fields back out of a page 1 image.
  static Header decode(const Page& page);
};

}  // namespace tessera
