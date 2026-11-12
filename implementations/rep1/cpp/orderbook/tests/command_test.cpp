#include <gtest/gtest.h>

#include "orderbook/command.hpp"

using namespace orderbook;

TEST(ParseCommand, PlainLimit) {
  auto c = parse_command("LIMIT a1 BUY 100 5");
  ASSERT_TRUE(c);
  EXPECT_EQ(c->type, CommandType::Limit);
  EXPECT_EQ(c->id, "a1");
  EXPECT_EQ(c->side, Side::Buy);
  EXPECT_EQ(c->price, 100);
  EXPECT_EQ(c->qty, 5);
  EXPECT_EQ(c->tif, TimeInForce::GoodTillCancel);
}

TEST(ParseCommand, IocAndFok) {
  EXPECT_EQ(parse_command("LIMIT a SELL 1 1 IOC")->tif, TimeInForce::ImmediateOrCancel);
  EXPECT_EQ(parse_command("LIMIT a SELL 1 1 FOK")->tif, TimeInForce::FillOrKill);
  EXPECT_FALSE(parse_command("LIMIT a SELL 1 1 GTC"));
}

TEST(ParseCommand, OtherCommands) {
  auto m = parse_command("MARKET m SELL 7");
  ASSERT_TRUE(m);
  EXPECT_EQ(m->type, CommandType::Market);
  EXPECT_EQ(m->qty, 7);
  EXPECT_EQ(parse_command("CANCEL x")->type, CommandType::Cancel);
  auto r = parse_command("REPLACE x 10 20");
  ASSERT_TRUE(r);
  EXPECT_EQ(r->price, 10);
  EXPECT_EQ(r->qty, 20);
  EXPECT_EQ(parse_command("BOOK")->type, CommandType::Book);
}

TEST(ParseCommand, IdsMayBeKeywordsOrPunctuation) {
  auto c = parse_command("LIMIT BUY SELL 5 5 IOC");
  ASSERT_TRUE(c);
  EXPECT_EQ(c->id, "BUY");
  EXPECT_EQ(c->side, Side::Sell);
  EXPECT_EQ(parse_command("CANCEL BOOK")->id, "BOOK");
  EXPECT_EQ(parse_command("CANCEL !~#$%")->id, "!~#$%");
}

TEST(ParseCommand, IdLengthLimitChecked) {
  const std::string ok = "CANCEL " + std::string(32, 'x');
  const std::string too_long = "CANCEL " + std::string(33, 'x');
  EXPECT_TRUE(parse_command(ok));
  EXPECT_FALSE(parse_command(too_long));
}

TEST(ParseCommand, LargeValues) {
  auto c = parse_command("LIMIT a BUY 1000000000 1000000000");
  ASSERT_TRUE(c);
  EXPECT_EQ(c->price, 1000000000);
  EXPECT_EQ(c->qty, 1000000000);
}

TEST(ParseCommand, Malformed) {
  EXPECT_FALSE(parse_command(""));
  EXPECT_FALSE(parse_command("FOO"));
  EXPECT_FALSE(parse_command("LIMIT a BUY 100"));
  EXPECT_FALSE(parse_command("LIMIT a HOLD 100 5"));
  EXPECT_FALSE(parse_command("LIMIT a BUY 0 5"));
  EXPECT_FALSE(parse_command("LIMIT a BUY 01 5"));
  EXPECT_FALSE(parse_command("LIMIT a BUY -1 5"));
  EXPECT_FALSE(parse_command("LIMIT a BUY 1x 5"));
  EXPECT_FALSE(parse_command("LIMIT a  BUY 1 5"));
  EXPECT_FALSE(parse_command("LIMIT a BUY 1 5 "));
  EXPECT_FALSE(parse_command("MARKET a BUY"));
  EXPECT_FALSE(parse_command("CANCEL"));
  EXPECT_FALSE(parse_command("CANCEL a b"));
  EXPECT_FALSE(parse_command("REPLACE a 1"));
  EXPECT_FALSE(parse_command("BOOK now"));
}
