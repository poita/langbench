#include <gtest/gtest.h>

#include "orderbook/order_book.hpp"

using namespace orderbook;
using T = Event::Type;

namespace {

Event trade(std::string taker, std::string maker, Price p, Qty q) {
  Event e; e.type = T::Trade; e.id = std::move(taker); e.maker = std::move(maker); e.price = p; e.qty = q;
  return e;
}
Event filled(std::string id) { Event e; e.type = T::Filled; e.id = std::move(id); return e; }
Event rest(std::string id) { Event e; e.type = T::Rest; e.id = std::move(id); return e; }
Event cancelled(std::string id, Qty q) { Event e; e.type = T::Cancel; e.id = std::move(id); e.qty = q; return e; }
Event reject(std::string id) { Event e; e.type = T::Reject; e.id = std::move(id); return e; }
Event level(Side s, Price p, Qty q, std::size_t n) {
  Event e; e.type = T::Level; e.side = s; e.price = p; e.qty = q; e.orders = n; return e;
}
Event book_end() { Event e; e.type = T::BookEnd; return e; }

using Events = std::vector<Event>;

class OrderBookTest : public ::testing::Test {
 protected:
  void buy(const char* id, Price p, Qty q, TimeInForce t = TimeInForce::GoodTillCancel) {
    sink.clear(); book.limit(id, Side::Buy, p, q, t, sink);
  }
  void sell(const char* id, Price p, Qty q, TimeInForce t = TimeInForce::GoodTillCancel) {
    sink.clear(); book.limit(id, Side::Sell, p, q, t, sink);
  }
  Events snap() { sink.clear(); book.snapshot(sink); return sink.events(); }
  const Events& ev() const { return sink.events(); }

  OrderBook book;
  RecordingSink sink;
};

constexpr auto IOC = TimeInForce::ImmediateOrCancel;
constexpr auto FOK = TimeInForce::FillOrKill;

}  // namespace

TEST_F(OrderBookTest, EmptyBookSnapshot) {
  EXPECT_EQ(snap(), Events{book_end()});
}

TEST_F(OrderBookTest, RestingOrderAppearsInSnapshot) {
  buy("b1", 100, 5);
  EXPECT_EQ(ev(), Events{rest("b1")});
  EXPECT_EQ(snap(), (Events{level(Side::Buy, 100, 5, 1), book_end()}));
  EXPECT_EQ(book.best_bid(), 100);
  EXPECT_FALSE(book.best_ask());
}

TEST_F(OrderBookTest, SweepsLevelsAtMakerPriceAndFifo) {
  sell("s1", 101, 5); sell("s2", 103, 5); sell("s3", 102, 5); sell("s4", 104, 5);
  buy("b1", 103, 12);
  EXPECT_EQ(ev(), (Events{trade("b1", "s1", 101, 5), filled("s1"), trade("b1", "s3", 102, 5),
                          filled("s3"), trade("b1", "s2", 103, 2), filled("b1")}));
  EXPECT_EQ(snap(), (Events{level(Side::Sell, 103, 3, 1), level(Side::Sell, 104, 5, 1), book_end()}));
}

TEST_F(OrderBookTest, TimePriorityWithinLevel) {
  buy("b1", 100, 5); buy("b2", 100, 5); buy("b3", 100, 5);
  sell("s", 100, 7);
  EXPECT_EQ(ev(), (Events{trade("s", "b1", 100, 5), filled("b1"), trade("s", "b2", 100, 2), filled("s")}));
}

TEST_F(OrderBookTest, PartialFillRestsRemainder) {
  sell("s1", 100, 3);
  buy("b1", 100, 10);
  EXPECT_EQ(ev(), (Events{trade("b1", "s1", 100, 3), filled("s1"), rest("b1")}));
  EXPECT_EQ(snap(), (Events{level(Side::Buy, 100, 7, 1), book_end()}));
}

TEST_F(OrderBookTest, NoCrossRests) {
  sell("s1", 101, 3);
  buy("b1", 100, 3);
  EXPECT_EQ(ev(), Events{rest("b1")});
  EXPECT_EQ(book.order_count(), 2u);
}

TEST_F(OrderBookTest, IocCancelsRemainder) {
  sell("s1", 100, 5);
  buy("b1", 100, 8, IOC);
  EXPECT_EQ(ev(), (Events{trade("b1", "s1", 100, 5), filled("s1"), cancelled("b1", 3)}));
  EXPECT_FALSE(book.contains("b1"));
  buy("b2", 99, 8, IOC);
  EXPECT_EQ(ev(), Events{cancelled("b2", 8)});
}

TEST_F(OrderBookTest, FokRejectedWithoutSideEffects) {
  sell("s1", 100, 5); sell("s2", 102, 5);
  buy("f", 101, 6, FOK);
  EXPECT_EQ(ev(), Events{reject("f")});
  EXPECT_EQ(book.order_count(), 2u);
  buy("f2", 102, 10, FOK);
  EXPECT_EQ(ev(), (Events{trade("f2", "s1", 100, 5), filled("s1"), trade("f2", "s2", 102, 5),
                          filled("s2"), filled("f2")}));
  EXPECT_EQ(book.order_count(), 0u);
}

TEST_F(OrderBookTest, FokAvailabilityUsesSixtyFourBitSums) {
  sell("s1", 100, 1000000000); sell("s2", 100, 1000000000); sell("s3", 100, 1000000000);
  sell("s4", 100, 1000000000); sell("s5", 100, 1000000000);
  EXPECT_EQ(snap()[0], level(Side::Sell, 100, 5000000000LL, 5));
  buy("f1", 100, 5000000001LL, FOK);  // one more than the 5e9 available
  EXPECT_EQ(ev(), Events{reject("f1")});
  buy("f2", 100, 5000000000LL, FOK);  // exactly what is available
  EXPECT_EQ(ev().back(), filled("f2"));
  EXPECT_EQ(book.order_count(), 0u);
}

TEST_F(OrderBookTest, MarketOrders) {
  sink.clear(); book.market("m1", Side::Buy, 4, sink);
  EXPECT_EQ(ev(), Events{cancelled("m1", 4)});
  sell("s1", 100, 3); sell("s2", 200, 3);
  sink.clear(); book.market("m2", Side::Buy, 5, sink);
  EXPECT_EQ(ev(), (Events{trade("m2", "s1", 100, 3), filled("s1"), trade("m2", "s2", 200, 2), filled("m2")}));
  sink.clear(); book.market("m3", Side::Buy, 5, sink);
  EXPECT_EQ(ev(), (Events{trade("m3", "s2", 200, 1), filled("s2"), cancelled("m3", 4)}));
}

TEST_F(OrderBookTest, CancelResting) {
  buy("b1", 100, 10); buy("b2", 100, 4);
  sell("s", 100, 3);  // takes from b1
  sink.clear(); book.cancel("b1", sink);
  EXPECT_EQ(ev(), Events{cancelled("b1", 7)});
  EXPECT_EQ(snap(), (Events{level(Side::Buy, 100, 4, 1), book_end()}));
  sink.clear(); book.cancel("b1", sink);
  EXPECT_EQ(ev(), Events{reject("b1")});
}

TEST_F(OrderBookTest, CancelMiddleOfQueueAndLastOrderRemovesLevel) {
  buy("a", 100, 1); buy("b", 100, 2); buy("c", 100, 3);
  sink.clear(); book.cancel("b", sink);
  EXPECT_EQ(snap(), (Events{level(Side::Buy, 100, 4, 2), book_end()}));
  sell("s", 100, 1);
  EXPECT_EQ(ev(), (Events{trade("s", "a", 100, 1), filled("a"), filled("s")}));
  sink.clear(); book.cancel("c", sink);
  EXPECT_EQ(snap(), Events{book_end()});
  EXPECT_EQ(book.bid_level_count(), 0u);
}

TEST_F(OrderBookTest, CancelRejectsUnknownAndNonResting) {
  sink.clear(); book.cancel("ghost", sink);
  EXPECT_EQ(ev(), Events{reject("ghost")});
  sell("s", 100, 1);
  buy("b", 100, 1);  // fills both
  sink.clear(); book.cancel("s", sink);
  EXPECT_EQ(ev(), Events{reject("s")});
  sink.clear(); book.cancel("b", sink);
  EXPECT_EQ(ev(), Events{reject("b")});
}

TEST_F(OrderBookTest, ReplacePriorityRules) {
  buy("b1", 100, 10); sell("s1", 105, 4); sell("s2", 106, 4);
  sink.clear(); book.replace("b1", 105, 6, sink);
  EXPECT_EQ(ev(), (Events{trade("b1", "s1", 105, 4), filled("s1"), rest("b1")}));
  EXPECT_EQ(snap(), (Events{level(Side::Buy, 105, 2, 1), level(Side::Sell, 106, 4, 1), book_end()}));
  sink.clear(); book.replace("b1", 110, 20, sink);
  EXPECT_EQ(ev(), (Events{trade("b1", "s2", 106, 4), filled("s2"), rest("b1")}));
  sink.clear(); book.replace("b1", 110, 3, sink);
  EXPECT_EQ(ev(), Events{rest("b1")});
  sink.clear(); book.cancel("b1", sink);
  EXPECT_EQ(ev(), Events{cancelled("b1", 3)});
}

TEST_F(OrderBookTest, ReplaceDownKeepsPlaceUpLosesIt) {
  buy("a", 100, 5); buy("b", 100, 5);
  sink.clear(); book.replace("a", 100, 2, sink);  // keeps priority
  sell("s", 100, 1);
  EXPECT_EQ(ev(), (Events{trade("s", "a", 100, 1), filled("s")}));
  sink.clear(); book.replace("a", 100, 6, sink);  // quantity up: to the back
  sell("s2", 100, 1);
  EXPECT_EQ(ev(), (Events{trade("s2", "b", 100, 1), filled("s2")}));
}

TEST_F(OrderBookTest, ReplaceToSamePriceLevelOfOtherOrderLosesPriority) {
  buy("a", 100, 5); buy("b", 101, 5);
  sink.clear(); book.replace("a", 101, 3, sink);  // price change: behind b at 101
  sell("s", 101, 6);
  EXPECT_EQ(ev(), (Events{trade("s", "b", 101, 5), filled("b"), trade("s", "a", 101, 1), filled("s")}));
}

TEST_F(OrderBookTest, ReplaceRejectsNonResting) {
  sink.clear(); book.replace("x", 1, 1, sink);
  EXPECT_EQ(ev(), Events{reject("x")});
}

TEST_F(OrderBookTest, ReplaceFilledOrderCompletelyReportsFilled) {
  sell("s", 100, 5); buy("b", 90, 5);
  sink.clear(); book.replace("b", 100, 5, sink);
  EXPECT_EQ(ev(), (Events{trade("b", "s", 100, 5), filled("s"), filled("b")}));
  EXPECT_EQ(book.order_count(), 0u);
}

TEST_F(OrderBookTest, IdsMayBeReusedAfterLeavingTheBookByReplace) {
  buy("a", 100, 5);
  sink.clear(); book.replace("a", 99, 5, sink);
  EXPECT_TRUE(book.contains("a"));
  EXPECT_EQ(book.order_count(), 1u);
}

TEST_F(OrderBookTest, LevelTotalsBeyondFourBillion) {
  for (int i = 0; i < 5; ++i) buy(("b" + std::to_string(i)).c_str(), 100, 1000000000);
  EXPECT_EQ(snap()[0], level(Side::Buy, 100, 5000000000LL, 5));
}

TEST_F(OrderBookTest, ManyLevelsBestFirst) {
  for (int p = 1; p <= 1000; ++p) buy(("b" + std::to_string(p)).c_str(), p, 1);
  for (int p = 1001; p <= 2000; ++p) sell(("s" + std::to_string(p)).c_str(), p, 1);
  auto s = snap();
  ASSERT_EQ(s.size(), 2001u);
  EXPECT_EQ(s.front(), level(Side::Buy, 1000, 1, 1));
  EXPECT_EQ(s[999], level(Side::Buy, 1, 1, 1));
  EXPECT_EQ(s[1000], level(Side::Sell, 1001, 1, 1));
  EXPECT_EQ(book.bid_level_count(), 1000u);
  EXPECT_EQ(book.ask_level_count(), 1000u);
}
