#pragma once
/// @file order_book.hpp
/// A single-instrument limit order book with price-time priority.

#include <deque>
#include <functional>
#include <optional>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "orderbook/command.hpp"
#include "orderbook/detail/book_side.hpp"
#include "orderbook/event.hpp"
#include "orderbook/types.hpp"

namespace orderbook {

/// Limit order book. Every operation reports what happened to an EventSink,
/// in the order the events occur.
///
/// Costs: a command is O(fills + levels visited * log P); CANCEL/REPLACE add
/// one hash lookup; best-price access is O(1); a FOK check is O(levels
/// crossed); a snapshot is O(levels).
///
/// Order ids are opaque byte strings of 1..kMaxIdLength bytes. The caller
/// guarantees an id passed to limit() is not currently resting.
/// The book is not thread-safe.
class OrderBook {
 public:
  OrderBook() = default;
  OrderBook(const OrderBook&) = delete;
  OrderBook& operator=(const OrderBook&) = delete;

  /// LIMIT: match against the opposite side, then (for GoodTillCancel) rest
  /// the remainder. FillOrKill is rejected untouched if it cannot fully fill.
  void limit(std::string_view id, Side side, Price price, Qty qty, TimeInForce tif,
             EventSink& sink);

  /// MARKET: match with no price limit; the remainder is cancelled.
  void market(std::string_view id, Side side, Qty qty, EventSink& sink);

  /// CANCEL: remove a resting order, or reject if `id` is not resting.
  void cancel(std::string_view id, EventSink& sink);

  /// REPLACE: set the new remaining quantity and price of a resting order.
  /// Price unchanged and quantity not increased keeps queue position;
  /// otherwise the order is re-entered as a new LIMIT with the same id/side.
  void replace(std::string_view id, Price price, Qty qty, EventSink& sink);

  /// BOOK: report every non-empty level, bids best first, then asks, then
  /// on_book_end(). Does not modify the book.
  void snapshot(EventSink& sink) const;

  /// Execute any parsed command (dispatches to the methods above).
  void execute(const Command& cmd, EventSink& sink);

  // ---- queries --------------------------------------------------------------
  std::size_t order_count() const noexcept { return index_.size(); }
  std::size_t bid_level_count() const noexcept { return bids_.level_count(); }
  std::size_t ask_level_count() const noexcept { return asks_.level_count(); }
  bool contains(std::string_view id) const { return index_.count(id) != 0; }
  std::optional<Price> best_bid() const;
  std::optional<Price> best_ask() const;

 private:
  using BidSide = detail::BookSide<std::greater<Price>>;
  using AskSide = detail::BookSide<std::less<Price>>;

  /// Match a taker against `opp`; returns its unfilled remainder.
  template <class Opposite>
  Qty sweep(Opposite& opp, std::string_view taker, Price limit, Qty qty, EventSink& sink);

  detail::Order& acquire(std::string_view id, Side side, Price price, Qty qty);
  void release(detail::Order& o);
  void remove_resting(detail::Order& o);

  BidSide bids_;
  AskSide asks_;
  // Orders live in a deque (stable addresses) and are recycled via free_.
  std::deque<detail::Order> pool_;
  std::vector<detail::Order*> free_;
  // Keys view into the Order's inline id buffer; entries are erased before an
  // Order is recycled.
  std::unordered_map<std::string_view, detail::Order*> index_;
};

}  // namespace orderbook
