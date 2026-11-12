#include "orderbook/event.hpp"

namespace orderbook {

void RecordingSink::on_trade(std::string_view taker, std::string_view maker, Price price, Qty qty) {
  Event e;
  e.type = Event::Type::Trade;
  e.id = taker;
  e.maker = maker;
  e.price = price;
  e.qty = qty;
  events_.push_back(std::move(e));
}

void RecordingSink::on_filled(std::string_view id) {
  Event e;
  e.type = Event::Type::Filled;
  e.id = id;
  events_.push_back(std::move(e));
}

void RecordingSink::on_rest(std::string_view id) {
  Event e;
  e.type = Event::Type::Rest;
  e.id = id;
  events_.push_back(std::move(e));
}

void RecordingSink::on_cancel(std::string_view id, Qty remaining) {
  Event e;
  e.type = Event::Type::Cancel;
  e.id = id;
  e.qty = remaining;
  events_.push_back(std::move(e));
}

void RecordingSink::on_reject(std::string_view id) {
  Event e;
  e.type = Event::Type::Reject;
  e.id = id;
  events_.push_back(std::move(e));
}

void RecordingSink::on_level(Side side, Price price, Qty total_qty, std::size_t n_orders) {
  Event e;
  e.type = Event::Type::Level;
  e.side = side;
  e.price = price;
  e.qty = total_qty;
  e.orders = n_orders;
  events_.push_back(std::move(e));
}

void RecordingSink::on_book_end() {
  Event e;
  e.type = Event::Type::BookEnd;
  events_.push_back(std::move(e));
}

}  // namespace orderbook
