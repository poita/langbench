#include "test_helpers.hpp"

using namespace chessperft;

namespace {
struct Case {
  const char* name;
  const char* fen;
  std::vector<std::uint64_t> counts;  // counts[d] = perft(d), starting at depth 1
};

const Case kCases[] = {
    {"startpos", "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
     {20, 400, 8902, 197281}},
    {"kiwipete", "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
     {48, 2039, 97862}},
    {"position3", "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", {14, 191, 2812, 43238}},
    {"position4", "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
     {6, 264, 9467}},
    {"position4_mirrored", "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1",
     {6, 264, 9467}},
    {"position5", "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
     {44, 1486, 62379}},
    {"position6", "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
     {46, 2079, 89890}},
};
}  // namespace

TEST(Perft, DepthZeroIsOne) {
  EXPECT_EQ(perft(Position::startPosition(), 0), 1u);
}

TEST(Perft, PublishedValues) {
  for (const Case& c : kCases) {
    const Position pos = mustParse(c.fen);
    for (std::size_t i = 0; i < c.counts.size(); ++i) {
      EXPECT_EQ(perft(pos, static_cast<int>(i) + 1), c.counts[i]) << c.name << " depth " << i + 1;
    }
  }
}

TEST(Perft, KiwipeteDepth4) {
  EXPECT_EQ(perft(mustParse(kCases[1].fen), 4), 4085603u);
}

TEST(Perft, StalemateAndMateContributeNothing) {
  EXPECT_EQ(perft(mustParse("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"), 3), 0u);
  EXPECT_EQ(perft(mustParse("R5k1/5ppp/8/8/8/8/8/6K1 b - - 0 1"), 1), 0u);
}

TEST(Divide, SortedAndSumsToPerft) {
  const Position pos = mustParse(kCases[1].fen);
  const auto entries = divide(pos, 3);
  EXPECT_EQ(entries.size(), 48u);
  std::uint64_t total = 0;
  std::string previous;
  for (const auto& e : entries) {
    const std::string uci = e.move.toUci();
    EXPECT_LT(previous, uci);
    previous = uci;
    total += e.nodes;
  }
  EXPECT_EQ(total, 97862u);
}

TEST(Divide, DepthOneCountsAreOne) {
  for (const auto& e : divide(Position::startPosition(), 1)) EXPECT_EQ(e.nodes, 1u);
}
