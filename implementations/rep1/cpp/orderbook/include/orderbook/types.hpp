#pragma once
/// @file types.hpp
/// Fundamental value types shared by every module.

#include <cstdint>
#include <limits>

namespace orderbook {

/// Price in integer ticks. Signed 64-bit so arithmetic on prices never wraps.
using Price = std::int64_t;

/// Quantity. All sums of quantities (level totals, FOK availability) can
/// exceed 2^32, so every quantity is 64-bit.
using Qty = std::int64_t;

inline constexpr Price kMinPrice = 0;
inline constexpr Price kMaxPrice = std::numeric_limits<Price>::max();

/// Maximum length, in bytes, of an order identifier.
inline constexpr std::size_t kMaxIdLength = 32;

enum class Side : std::uint8_t { Buy, Sell };

/// Time-in-force of a limit order.
enum class TimeInForce : std::uint8_t {
  GoodTillCancel,     ///< remainder rests in the book (plain LIMIT)
  ImmediateOrCancel,  ///< remainder is discarded (IOC)
  FillOrKill          ///< all-or-nothing, checked before any fill (FOK)
};

constexpr Side opposite(Side s) noexcept {
  return s == Side::Buy ? Side::Sell : Side::Buy;
}

}  // namespace orderbook
