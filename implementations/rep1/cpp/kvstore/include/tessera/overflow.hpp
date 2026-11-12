#pragma once
/// \file overflow.hpp
/// Overflow page chains for documents longer than the inline limit (spec section 9).

#include <cstdint>
#include <string>
#include <string_view>

#include "tessera/pager.hpp"

namespace tessera {

/// Writes `data` as a chain of overflow pages, allocating in chain order, and
/// returns the first page (0 when `data` is empty).
std::uint32_t write_overflow_chain(Pager& pager, std::string_view data);
/// Reads a chain's payload bytes.
std::string read_overflow_chain(const Pager& pager, std::uint32_t first);
/// Frees a chain, first page first.
void free_overflow_chain(Pager& pager, std::uint32_t first);

}  // namespace tessera
