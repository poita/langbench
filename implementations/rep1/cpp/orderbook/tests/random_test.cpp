// Differential test: the real book against a deliberately naive model that
// scans vectors and recomputes everything from scratch.
#include <gtest/gtest.h>

#include <algorithm>
#include <random>

#include "orderbook/order_book.hpp"

using namespace orderbook;

namespace {

class NaiveBook {
 public:
  struct O { std::string id; Side side; Price price; Qty rem; };

  void limit(const std::string& id, Side side, Price price, Qty qty, TimeInForce tif, EventSink& s) {
    if (tif == TimeInForce::FillOrKill) {
      Qty avail = 0;
      for (auto& o : orders_)
        if (o.side != side && crosses(side, price, o.price)) avail += o.rem;
      if (avail < qty) { s.on_reject(id); return; }
    }
    Qty rem = match(id, side, price, qty, s);
    if (rem == 0) s.on_filled(id);
    else if (tif == TimeInForce::GoodTillCancel) { orders_.push_back({id, side, price, rem}); s.on_rest(id); }
    else s.on_cancel(id, rem);
  }
  void market(const std::string& id, Side side, Qty qty, EventSink& s) {
    Qty rem = match(id, side, side == Side::Buy ? kMaxPrice : kMinPrice, qty, s);
    if (rem == 0) s.on_filled(id); else s.on_cancel(id, rem);
  }
  void cancel(const std::string& id, EventSink& s) {
    auto it = find(id);
    if (it == orders_.end()) { s.on_reject(id); return; }
    s.on_cancel(id, it->rem);
    orders_.erase(it);
  }
  void replace(const std::string& id, Price price, Qty qty, EventSink& s) {
    auto it = find(id);
    if (it == orders_.end()) { s.on_reject(id); return; }
    if (it->price == price && qty <= it->rem) { it->rem = qty; s.on_rest(id); return; }
    Side side = it->side;
    orders_.erase(it);
    limit(id, side, price, qty, TimeInForce::GoodTillCancel, s);
  }
  void snapshot(EventSink& s) const {
    for (Side side : {Side::Buy, Side::Sell}) {
      std::vector<Price> prices;
      for (auto& o : orders_) if (o.side == side) prices.push_back(o.price);
      std::sort(prices.begin(), prices.end());
      prices.erase(std::unique(prices.begin(), prices.end()), prices.end());
      if (side == Side::Buy) std::reverse(prices.begin(), prices.end());
      for (Price p : prices) {
        Qty tot = 0; std::size_t n = 0;
        for (auto& o : orders_) if (o.side == side && o.price == p) { tot += o.rem; ++n; }
        s.on_level(side, p, tot, n);
      }
    }
    s.on_book_end();
  }

 private:
  static bool crosses(Side taker, Price limit, Price resting) {
    return taker == Side::Buy ? resting <= limit : resting >= limit;
  }
  std::vector<O>::iterator find(const std::string& id) {
    return std::find_if(orders_.begin(), orders_.end(), [&](const O& o) { return o.id == id; });
  }
  Qty match(const std::string& id, Side side, Price limit, Qty qty, EventSink& s) {
    while (qty > 0) {
      auto best = orders_.end();
      for (auto it = orders_.begin(); it != orders_.end(); ++it) {
        if (it->side == side || !crosses(side, limit, it->price)) continue;
        if (best == orders_.end() ||
            (side == Side::Buy ? it->price < best->price : it->price > best->price))
          best = it;  // strict comparison keeps the earliest at equal price
      }
      if (best == orders_.end()) break;
      Qty t = std::min(qty, best->rem);
      s.on_trade(id, best->id, best->price, t);
      qty -= t; best->rem -= t;
      if (best->rem == 0) { s.on_filled(best->id); orders_.erase(best); }
    }
    return qty;
  }
  std::vector<O> orders_;
};

void run_random(unsigned seed, int steps, int price_span, int qty_max) {
  std::mt19937_64 rng(seed);
  OrderBook book;
  NaiveBook ref;
  RecordingSink a, b;
  std::vector<std::string> ids;
  int next_id = 0;
  auto pick = [&](int n) { return static_cast<int>(rng() % static_cast<unsigned>(n)); };
  auto price = [&] { return static_cast<Price>(1000 + pick(price_span)); };
  auto qty = [&] { return static_cast<Qty>(1 + pick(qty_max)); };
  auto some_id = [&]() -> std::string {
    if (ids.empty() || pick(10) == 0) return "ghost" + std::to_string(pick(5));
    return ids[pick(static_cast<int>(ids.size()))];
  };

  for (int i = 0; i < steps; ++i) {
    a.clear(); b.clear();
    const int k = pick(100);
    const Side side = pick(2) ? Side::Buy : Side::Sell;
    if (k < 45) {
      std::string id = "o" + std::to_string(next_id++);
      ids.push_back(id);
      const int f = pick(10);
      TimeInForce tif = f == 0 ? TimeInForce::ImmediateOrCancel
                      : f == 1 ? TimeInForce::FillOrKill : TimeInForce::GoodTillCancel;
      Price p = price(); Qty q = qty();
      book.limit(id, side, p, q, tif, a); ref.limit(id, side, p, q, tif, b);
    } else if (k < 52) {
      std::string id = "o" + std::to_string(next_id++);
      ids.push_back(id);
      Qty q = qty();
      book.market(id, side, q, a); ref.market(id, side, q, b);
    } else if (k < 72) {
      std::string id = some_id();
      book.cancel(id, a); ref.cancel(id, b);
    } else if (k < 92) {
      std::string id = some_id();
      Price p = price(); Qty q = qty();
      book.replace(id, p, q, a); ref.replace(id, p, q, b);
    } else {
      book.snapshot(a); ref.snapshot(b);
    }
    ASSERT_EQ(a.events(), b.events()) << "seed " << seed << " step " << i;
  }
  a.clear(); b.clear();
  book.snapshot(a); ref.snapshot(b);
  EXPECT_EQ(a.events(), b.events());
}

}  // namespace

TEST(RandomDifferential, TightBookManyCrosses) {
  for (unsigned seed = 1; seed <= 20; ++seed) run_random(seed, 3000, 10, 20);
}

TEST(RandomDifferential, WideBook) {
  for (unsigned seed = 100; seed <= 105; ++seed) run_random(seed, 3000, 200, 50);
}

TEST(RandomDifferential, LargeQuantities) {
  for (unsigned seed = 200; seed <= 205; ++seed) run_random(seed, 2000, 8, 1000000000);
}
