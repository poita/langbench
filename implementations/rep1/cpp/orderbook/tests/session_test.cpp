#include <gtest/gtest.h>

#include <sstream>

#include "orderbook/session.hpp"

using namespace orderbook;

namespace {
std::string run(const std::string& in, SessionResult* res = nullptr) {
  std::ostringstream out;
  SessionResult r = run_session(in, out);
  if (res) *res = r;
  return out.str();
}
}  // namespace

TEST(Session, ZeroCommandsProducesNoOutput) {
  EXPECT_EQ(run("0\n"), "");
  EXPECT_EQ(run("0"), "");
  EXPECT_EQ(run(""), "");
}

TEST(Session, Example1) {
  const std::string in =
      "9\nLIMIT s1 SELL 101 5\nLIMIT s2 SELL 103 5\nLIMIT s3 SELL 102 5\nLIMIT s4 SELL 104 5\n"
      "LIMIT b1 BUY 103 12\nBOOK\nLIMIT b2 BUY 110 1\nLIMIT b3 BUY 103 9\nBOOK\n";
  const std::string want =
      "REST s1\nREST s2\nREST s3\nREST s4\nTRADE b1 s1 101 5\nFILLED s1\nTRADE b1 s3 102 5\n"
      "FILLED s3\nTRADE b1 s2 103 2\nFILLED b1\nASK 103 3 1\nASK 104 5 1\n--\n"
      "TRADE b2 s2 103 1\nFILLED b2\nTRADE b3 s2 103 2\nFILLED s2\nREST b3\n"
      "BID 103 7 1\nASK 104 5 1\n--\n";
  EXPECT_EQ(run(in), want);
}

TEST(Session, FinalNewlineOptional) {
  EXPECT_EQ(run("2\nLIMIT a BUY 5 1\nBOOK"), "REST a\nBID 5 1 1\n--\n");
}

TEST(Session, IdsEqualToKeywords) {
  EXPECT_EQ(run("4\nLIMIT BUY BUY 5 1\nLIMIT SELL SELL 5 1\nCANCEL BOOK\nBOOK\n"),
            "REST BUY\nTRADE SELL BUY 5 1\nFILLED BUY\nFILLED SELL\nREJECT BOOK\n--\n");
}

TEST(Session, BigQuantitiesSummed) {
  EXPECT_EQ(run("3\nLIMIT a BUY 5 1000000000\nLIMIT b BUY 5 1000000000\nBOOK\n"),
            "REST a\nREST b\nBID 5 2000000000 2\n--\n");
  std::string in = "6\n";
  for (int i = 0; i < 5; ++i) in += "LIMIT o" + std::to_string(i) + " SELL 7 1000000000\n";
  in += "BOOK\n";
  EXPECT_NE(run(in).find("ASK 7 5000000000 5\n"), std::string::npos);
}

TEST(Session, MalformedLineReported) {
  SessionResult r;
  const std::string out = run("2\nLIMIT a BUY 5 1\nWHAT\n", &r);
  EXPECT_FALSE(r.ok);
  EXPECT_EQ(out, "REST a\n");
  EXPECT_EQ(r.commands, 1u);
  EXPECT_NE(r.error.find("line 3"), std::string::npos);
}

TEST(Session, BadCount) {
  SessionResult r;
  run("abc\n", &r);
  EXPECT_FALSE(r.ok);
}
