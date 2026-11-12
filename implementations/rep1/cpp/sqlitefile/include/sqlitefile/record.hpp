#pragma once
/// \file record.hpp
/// Varints and the record format (table rows and index entries).

#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>
#include <vector>

#include "sqlitefile/value.hpp"

namespace sqlitefile {

/// A read-only view of bytes.
using ByteView = std::span<const std::uint8_t>;

/// Decodes a 1-9 byte varint starting at `data[pos]`, stores the signed
/// 64-bit result in `out` and returns the position just after it.
/// Throws FormatError if the data ends first.
std::size_t readVarint(ByteView data, std::size_t pos, std::int64_t& out);

/// Decodes a record into values. Stops after `max_columns` columns if given.
/// Throws FormatError for a malformed record.
std::vector<Value> decodeRecord(
    ByteView payload,
    std::size_t max_columns = std::numeric_limits<std::size_t>::max());

}  // namespace sqlitefile
