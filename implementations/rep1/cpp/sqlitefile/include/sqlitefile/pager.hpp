#pragma once
/// \file pager.hpp
/// The database file held in memory, its header, and page access.

#include <cstdint>
#include <filesystem>
#include <vector>

#include "sqlitefile/record.hpp"

namespace sqlitefile {

/// The fields of the 100-byte database header this library uses.
struct DatabaseHeader {
  std::uint32_t page_size = 0;           ///< bytes per page (65536 decoded)
  std::uint32_t reserved_bytes = 0;      ///< unused bytes at the end of each page
  std::uint32_t declared_page_count = 0; ///< "database size in pages" field
  std::uint32_t freelist_trunk = 0;      ///< first freelist trunk page, or 0
  std::uint32_t freelist_count = 0;      ///< total freelist pages
  std::uint32_t largest_root_page = 0;   ///< non-zero only with auto-vacuum
  std::uint32_t text_encoding = 0;       ///< 1 = UTF-8
};

/// Owns the bytes of a database file and hands out pages (numbered from 1).
class Pager {
 public:
  /// Reads the whole file. Throws Error if it cannot be read and FormatError
  /// if it is not a usable SQLite 3 database.
  static Pager open(const std::filesystem::path& path);
  /// Takes ownership of an in-memory database image.
  static Pager fromBytes(std::vector<std::uint8_t> bytes);

  const DatabaseHeader& header() const { return header_; }
  std::uint32_t pageSize() const { return header_.page_size; }
  /// Page size minus the reserved bytes: the `U` of the overflow formulas.
  std::uint32_t usableSize() const { return header_.page_size - header_.reserved_bytes; }
  /// Number of whole pages present in the file.
  std::uint32_t pageCount() const { return page_count_; }

  /// The bytes of page `number` (1-based). Throws FormatError if out of range.
  ByteView page(std::uint32_t number) const;

 private:
  Pager() = default;
  std::vector<std::uint8_t> bytes_;
  DatabaseHeader header_;
  std::uint32_t page_count_ = 0;
};

}  // namespace sqlitefile
