#include <gtest/gtest.h>

#include <vector>

#include "spiremark/rng.hpp"

using spiremark::Rng;

TEST(Rng, MatchesTheSpecifiedSequenceForSeed7) {
    Rng r(7);
    EXPECT_EQ(r.next(), 15130880334998875822ULL);
    EXPECT_EQ(r.next(), 17123930943180875438ULL);
    EXPECT_EQ(r.next(), 1648209070578717474ULL);
    EXPECT_EQ(r.next(), 1985375592982671918ULL);
    EXPECT_EQ(r.next(), 6908966637734145041ULL);
}

TEST(Rng, ZeroSeedIsReplaced) {
    Rng a(0), b(0x2545F4914F6CDD1DULL);
    EXPECT_EQ(a.next(), b.next());
}

TEST(Rng, ShuffleOfShortListsConsumesNothing) {
    Rng a(5), b(5);
    std::vector<int> empty, one{1};
    a.shuffle(empty);
    a.shuffle(one);
    EXPECT_EQ(a.next(), b.next());
}

TEST(Rng, ShuffleFollowsTheSpecifiedAlgorithm) {
    // SEED 7, list of 8: the first swap is (i=7, j=6) per SPEC.md 26.12.
    Rng r(7);
    std::vector<int> v{0, 1, 2, 3, 4, 5, 6, 7};
    r.shuffle(v);
    // Reference computed by hand-running the algorithm on the same stream.
    Rng ref(7);
    std::vector<int> w{0, 1, 2, 3, 4, 5, 6, 7};
    for (int i = 7; i >= 1; --i) std::swap(w[i], w[ref.below(i + 1)]);
    EXPECT_EQ(v, w);
}
