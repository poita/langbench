#pragma once
/// \file limits.hpp
/// Format constants fixed by the Tessera specification.

#include <cstddef>
#include <cstdint>

namespace tessera {

inline constexpr std::size_t kPageSize = 1024;
inline constexpr std::size_t kMaxKey = 128;
inline constexpr std::size_t kMaxIndexKey = 128;
inline constexpr std::size_t kMaxInline = 192;
inline constexpr std::size_t kOverflowPayload = 1012;
inline constexpr std::size_t kMaxDoc = 65536;
inline constexpr int kMaxDepth = 32;
inline constexpr std::size_t kNodeHeader = 16;
inline constexpr std::size_t kCapacity = 1008;
inline constexpr std::size_t kMinFill = 336;
inline constexpr std::size_t kMaxIndexes = 16;
inline constexpr std::size_t kMaxPath = 30;
inline constexpr std::size_t kMaxPathSegments = 8;
inline constexpr std::size_t kWalLimit = 262144;
inline constexpr std::int64_t kMaxLimit = 2147483647;

}  // namespace tessera
