#pragma once
/// @file event.hpp
/// The events an OrderBook reports, and the sink interface that receives them.

#include <string>
#include <string_view>
#include <vector>

#include "orderbook/types.hpp"

namespace orderbook {

/// Receiver of the events produced while commands execute.
///
/// String views passed to callbacks are only valid for the duration of the
/// call; copy them if you need to keep them.
class EventSink {
 public:
  virtual ~EventSink() = default;

  /// A fill between the incoming order (taker) and a resting order (maker),
  /// at the maker's price.
  virtual void on_trade(std::string_view taker, std::string_view maker, Price price, Qty qty) = 0;
  /// The order's remaining quantity reached zero.
  virtual void on_filled(std::string_view id) = 0;
  /// The order now rests in the book (also reported by a priority-keeping REPLACE).
  virtual void on_rest(std::string_view id) = 0;
  /// The order left the book, or never entered it, with `remaining` unfilled.
  virtual void on_cancel(std::string_view id, Qty remaining) = 0;
  /// The command was refused; nothing changed.
  virtual void on_reject(std::string_view id) = 0;
  /// One price level of a snapshot (bids best first, then asks best first).
  virtual void on_level(Side side, Price price, Qty total_qty, std::size_t n_orders) = 0;
  /// End of a snapshot.
  virtual void on_book_end() = 0;
};

/// A recorded event (see RecordingSink).
struct Event {
  enum class Type { Trade, Filled, Rest, Cancel, Reject, Level, BookEnd };

  Type type{};
  std::string id;      ///< taker id for Trade, order id otherwise
  std::string maker;   ///< Trade only
  Side side{};         ///< Level only
  Price price = 0;     ///< Trade, Level
  Qty qty = 0;         ///< Trade qty, Cancel remaining, Level total
  std::size_t orders = 0;  ///< Level only

  friend bool operator==(const Event&, const Event&) = default;
};

/// An EventSink that stores every event in a vector. Handy for tests and for
/// embedding the book where the textual format is not wanted.
class RecordingSink final : public EventSink {
 public:
  const std::vector<Event>& events() const noexcept { return events_; }
  void clear() { events_.clear(); }

  void on_trade(std::string_view taker, std::string_view maker, Price price, Qty qty) override;
  void on_filled(std::string_view id) override;
  void on_rest(std::string_view id) override;
  void on_cancel(std::string_view id, Qty remaining) override;
  void on_reject(std::string_view id) override;
  void on_level(Side side, Price price, Qty total_qty, std::size_t n_orders) override;
  void on_book_end() override;

 private:
  std::vector<Event> events_;
};

}  // namespace orderbook
