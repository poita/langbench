#pragma once
/// \file page.hpp
/// The raw page type and big-endian integer helpers.

#include <array>
#include <cstdint>

#include "tessera/limits.hpp"

namespace tessera {

using Page = std::array<std::uint8_t, kPageSize>;

inline std::uint16_t get16(const std::uint8_t* p) {
  return static_cast<std::uint16_t>((p[0] << 8) | p[1]);
}
inline std::uint32_t get32(const std::uint8_t* p) {
  return (std::uint32_t(p[0]) << 24) | (std::uint32_t(p[1]) << 16) | (std::uint32_t(p[2]) << 8) |
         std::uint32_t(p[3]);
}
inline std::uint64_t get64(const std::uint8_t* p) {
  return (std::uint64_t(get32(p)) << 32) | get32(p + 4);
}
inline void put16(std::uint8_t* p, std::uint16_t v) {
  p[0] = std::uint8_t(v >> 8);
  p[1] = std::uint8_t(v);
}
inline void put32(std::uint8_t* p, std::uint32_t v) {
  p[0] = std::uint8_t(v >> 24);
  p[1] = std::uint8_t(v >> 16);
  p[2] = std::uint8_t(v >> 8);
  p[3] = std::uint8_t(v);
}
inline void put64(std::uint8_t* p, std::uint64_t v) {
  put32(p, std::uint32_t(v >> 32));
  put32(p + 4, std::uint32_t(v));
}

/// Page type bytes (byte 0 of every page except page 1).
enum class PageType : std::uint8_t {
  Free = 0,
  PrimaryLeaf = 1,
  Interior = 2,
  Overflow = 3,
  IndexLeaf = 5,
};

}  // namespace tessera
