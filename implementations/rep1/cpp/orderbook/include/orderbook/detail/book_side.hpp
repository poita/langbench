#pragma once
/// @file detail/book_side.hpp
/// Internal: one side of the book as an ordered map of price levels.

#include <cassert>
#include <map>

#include "orderbook/detail/order.hpp"

namespace orderbook::detail {

/// Price levels of one side, ordered best-first according to `Better`
/// (`std::greater<Price>` for bids, `std::less<Price>` for asks).
///
/// The best level is `begin()` of an ordered map (O(1)); inserting or erasing
/// a level is O(log P). Level addresses are stable, so orders keep a plain
/// pointer to their level.
template <class Better>
class BookSide {
 public:
  using Levels = std::map<Price, Level, Better>;

  bool empty() const noexcept { return levels_.empty(); }
  std::size_t level_count() const noexcept { return levels_.size(); }
  const Levels& levels() const noexcept { return levels_; }

  Level& best() noexcept {
    assert(!levels_.empty());
    return levels_.begin()->second;
  }
  const Level& best() const noexcept {
    assert(!levels_.empty());
    return levels_.begin()->second;
  }

  /// Does a level at `level_price` cross an incoming order with limit `limit`?
  static bool crosses(Price level_price, Price limit) noexcept {
    return !Better{}(limit, level_price);
  }

  /// Append `o` (whose price/remaining are set) to the back of its level.
  void push_back(Order& o) {
    auto it = levels_.try_emplace(o.price, o.price).first;
    Level& lv = it->second;
    o.level = &lv;
    o.next = nullptr;
    o.prev = lv.tail;
    if (lv.tail) lv.tail->next = &o; else lv.head = &o;
    lv.tail = &o;
    ++lv.count;
    lv.total += o.remaining;
  }

  /// Unlink `o` from its level in O(1), without touching the level map.
  /// Returns the (possibly now empty) level.
  static Level& unlink(Order& o) noexcept {
    Level& lv = *o.level;
    if (o.prev) o.prev->next = o.next; else lv.head = o.next;
    if (o.next) o.next->prev = o.prev; else lv.tail = o.prev;
    --lv.count;
    lv.total -= o.remaining;
    o.prev = o.next = nullptr;
    o.level = nullptr;
    return lv;
  }

  /// Remove `o` from the book, erasing its level if it becomes empty.
  void remove(Order& o) {
    Level& lv = unlink(o);
    if (lv.head == nullptr) levels_.erase(lv.price);
  }

  /// Erase the best level (which must be empty).
  void erase_best() {
    assert(best().head == nullptr);
    levels_.erase(levels_.begin());
  }

  /// Total quantity at levels crossing `limit`, stopping once `need` is
  /// reached. O(levels visited).
  Qty available(Price limit, Qty need) const noexcept {
    Qty sum = 0;
    for (const auto& [price, lv] : levels_) {
      if (!crosses(price, limit)) break;
      sum += lv.total;
      if (sum >= need) break;
    }
    return sum;
  }

 private:
  Levels levels_;
};

}  // namespace orderbook::detail
