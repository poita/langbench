#pragma once
/// \file crc32.hpp
/// CRC-32 (reflected polynomial 0xEDB88320), implemented from scratch.

#include <cstddef>
#include <cstdint>

namespace tessera {

/// Incrementally updates a CRC. Start with `crc32_init()`, feed data with
/// `crc32_update`, finish with `crc32_final`.
constexpr std::uint32_t crc32_init() { return 0xFFFFFFFFu; }
std::uint32_t crc32_update(std::uint32_t state, const std::uint8_t* data, std::size_t size);
constexpr std::uint32_t crc32_final(std::uint32_t state) { return state ^ 0xFFFFFFFFu; }

/// One-shot CRC-32 of a buffer.
std::uint32_t crc32(const std::uint8_t* data, std::size_t size);

}  // namespace tessera
