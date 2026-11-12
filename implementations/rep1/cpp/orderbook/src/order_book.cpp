#include "orderbook/order_book.hpp"

#include <algorithm>

namespace orderbook {

using detail::Order;

detail::Order& OrderBook::acquire(std::string_view id, Side side, Price price, Qty qty) {
  Order* o;
  if (!free_.empty()) {
    o = free_.back();
    free_.pop_back();
  } else {
    o = &pool_.emplace_back();
  }
  o->set_id(id);
  o->side = side;
  o->price = price;
  o->remaining = qty;
  index_.emplace(o->id(), o);
  return *o;
}

void OrderBook::release(Order& o) {
  index_.erase(o.id());
  free_.push_back(&o);
}

void OrderBook::remove_resting(Order& o) {
  if (o.side == Side::Buy) bids_.remove(o); else asks_.remove(o);
  release(o);
}

template <class Opposite>
Qty OrderBook::sweep(Opposite& opp, std::string_view taker, Price limit, Qty qty,
                     EventSink& sink) {
  while (qty > 0 && !opp.empty()) {
    detail::Level& lv = opp.best();
    if (!Opposite::crosses(lv.price, limit)) break;
    while (qty > 0 && lv.head != nullptr) {
      Order& maker = *lv.head;
      const Qty t = std::min(qty, maker.remaining);
      sink.on_trade(taker, maker.id(), lv.price, t);
      qty -= t;
      maker.remaining -= t;
      lv.total -= t;
      if (maker.remaining == 0) {
        sink.on_filled(maker.id());
        Opposite::unlink(maker);
        release(maker);
      }
    }
    if (lv.head == nullptr) opp.erase_best();
  }
  return qty;
}

void OrderBook::limit(std::string_view id, Side side, Price price, Qty qty, TimeInForce tif,
                      EventSink& sink) {
  if (tif == TimeInForce::FillOrKill) {
    const Qty avail = side == Side::Buy ? asks_.available(price, qty) : bids_.available(price, qty);
    if (avail < qty) {
      sink.on_reject(id);
      return;
    }
  }
  const Qty rest = side == Side::Buy ? sweep(asks_, id, price, qty, sink)
                                     : sweep(bids_, id, price, qty, sink);
  if (rest == 0) {
    sink.on_filled(id);
  } else if (tif == TimeInForce::GoodTillCancel) {
    Order& o = acquire(id, side, price, rest);
    if (side == Side::Buy) bids_.push_back(o); else asks_.push_back(o);
    sink.on_rest(id);
  } else {
    sink.on_cancel(id, rest);
  }
}

void OrderBook::market(std::string_view id, Side side, Qty qty, EventSink& sink) {
  const Qty rest = side == Side::Buy ? sweep(asks_, id, kMaxPrice, qty, sink)
                                     : sweep(bids_, id, kMinPrice, qty, sink);
  if (rest == 0) sink.on_filled(id); else sink.on_cancel(id, rest);
}

void OrderBook::cancel(std::string_view id, EventSink& sink) {
  auto it = index_.find(id);
  if (it == index_.end()) {
    sink.on_reject(id);
    return;
  }
  Order& o = *it->second;
  sink.on_cancel(id, o.remaining);
  remove_resting(o);
}

void OrderBook::replace(std::string_view id, Price price, Qty qty, EventSink& sink) {
  auto it = index_.find(id);
  if (it == index_.end()) {
    sink.on_reject(id);
    return;
  }
  Order& o = *it->second;
  if (price == o.price && qty <= o.remaining) {
    o.level->total -= o.remaining - qty;
    o.remaining = qty;
    sink.on_rest(id);
    return;
  }
  const Side side = o.side;
  remove_resting(o);
  limit(id, side, price, qty, TimeInForce::GoodTillCancel, sink);
}

void OrderBook::snapshot(EventSink& sink) const {
  for (const auto& [price, lv] : bids_.levels()) sink.on_level(Side::Buy, price, lv.total, lv.count);
  for (const auto& [price, lv] : asks_.levels()) sink.on_level(Side::Sell, price, lv.total, lv.count);
  sink.on_book_end();
}

void OrderBook::execute(const Command& c, EventSink& sink) {
  switch (c.type) {
    case CommandType::Limit:   limit(c.id, c.side, c.price, c.qty, c.tif, sink); break;
    case CommandType::Market:  market(c.id, c.side, c.qty, sink); break;
    case CommandType::Cancel:  cancel(c.id, sink); break;
    case CommandType::Replace: replace(c.id, c.price, c.qty, sink); break;
    case CommandType::Book:    snapshot(sink); break;
  }
}

std::optional<Price> OrderBook::best_bid() const {
  if (bids_.empty()) return std::nullopt;
  return bids_.best().price;
}

std::optional<Price> OrderBook::best_ask() const {
  if (asks_.empty()) return std::nullopt;
  return asks_.best().price;
}

}  // namespace orderbook
