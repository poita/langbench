// Using the orderbook library directly, without the text protocol.
#include <iostream>

#include "orderbook/order_book.hpp"
#include "orderbook/text_writer.hpp"

int main() {
  using namespace orderbook;

  OrderBook book;
  TextEventWriter out(std::cout);  // renders events in the SPEC.md text format

  book.limit("s1", Side::Sell, 101, 5, TimeInForce::GoodTillCancel, out);
  book.limit("s2", Side::Sell, 102, 5, TimeInForce::GoodTillCancel, out);
  book.limit("b1", Side::Buy, 102, 8, TimeInForce::GoodTillCancel, out);  // trades with s1, s2
  book.replace("s2", 102, 1, out);                                         // keeps priority
  book.market("m1", Side::Buy, 10, out);                                   // sweeps, cancels rest
  book.cancel("nope", out);                                                // REJECT
  book.snapshot(out);
  out.flush();

  // Or collect events as data:
  RecordingSink rec;
  book.limit("b2", Side::Buy, 99, 3, TimeInForce::GoodTillCancel, rec);
  std::cout << "recorded " << rec.events().size() << " event(s); best bid "
            << *book.best_bid() << '\n';
}
