#pragma once
/// @file detail/order.hpp
/// Internal: resting order and price level records. Not part of the public API.

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string_view>

#include "orderbook/types.hpp"

namespace orderbook::detail {

struct Level;

/// A resting order: a node of its level's intrusive doubly linked FIFO queue,
/// which makes removal from the middle O(1).
struct Order {
  std::array<char, kMaxIdLength> id_buf{};
  std::uint8_t id_len = 0;
  Side side = Side::Buy;
  Price price = 0;
  Qty remaining = 0;
  Order* prev = nullptr;
  Order* next = nullptr;
  Level* level = nullptr;

  std::string_view id() const noexcept { return {id_buf.data(), id_len}; }
  void set_id(std::string_view s) noexcept {
    id_len = static_cast<std::uint8_t>(s.size());
    std::memcpy(id_buf.data(), s.data(), s.size());
  }
};

/// All resting orders at one price on one side, plus running totals.
struct Level {
  explicit Level(Price p) : price(p) {}

  Price price;
  Qty total = 0;          ///< sum of remaining quantities
  std::size_t count = 0;  ///< number of orders
  Order* head = nullptr;  ///< oldest (next to be matched)
  Order* tail = nullptr;  ///< newest
};

}  // namespace orderbook::detail
