#include "test_helpers.hpp"

using namespace chessperft;

namespace {
std::string answer(const std::string& line) {
  const auto q = parseQuery(line);
  EXPECT_TRUE(q.has_value()) << line;
  return q ? answerQuery(*q) : "";
}
}  // namespace

TEST(Query, ParsesPerftAndDivide) {
  const auto p = parseQuery("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 3");
  ASSERT_TRUE(p);
  EXPECT_FALSE(p->divide);
  EXPECT_EQ(p->depth, 3);
  const auto d = parseQuery("8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1");
  ASSERT_TRUE(d);
  EXPECT_TRUE(d->divide);
  EXPECT_EQ(d->depth, 1);
}

TEST(Query, RejectsMalformedLines) {
  EXPECT_FALSE(parseQuery(""));
  EXPECT_FALSE(parseQuery("8/8/8/8/8/8/8/8 w - - 0 1"));                  // no depth
  EXPECT_FALSE(parseQuery("4k3/8/8/8/8/8/8/4K3 w - - 0 1 abc"));
  EXPECT_FALSE(parseQuery("4k3/8/8/8/8/8/8/4K3 w - - 0 1 divide 0"));
  EXPECT_FALSE(parseQuery("4k3/8/8/8/8/8/8/4K3 w - - 0 1 divide"));
}

TEST(Query, PerftOutput) {
  EXPECT_EQ(answer("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 1"), "20\n");
  EXPECT_EQ(answer("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 3"), "8902\n");
  EXPECT_EQ(answer("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1 0"), "1\n");
}

TEST(Query, DivideOutput) {
  EXPECT_EQ(answer("8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1"),
            "a6a5 1\na6b5 1\na7a8b 1\na7a8n 1\na7a8q 1\na7a8r 1\ntotal 6\n");
  EXPECT_EQ(answer("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1 divide 3"), "total 0\n");
}

TEST(Query, DivideWithCastlingMatchesSpecExample) {
  const std::string out = answer("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1 divide 2");
  EXPECT_NE(out.find("e1c1 23\n"), std::string::npos);
  EXPECT_NE(out.find("a1a8 3\n"), std::string::npos);
  EXPECT_NE(out.find("total 568\n"), std::string::npos);
}
