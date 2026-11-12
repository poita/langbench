#include <gtest/gtest.h>

#include <algorithm>
#include <random>
#include <vector>

#include "sat/heap.hpp"
#include "sat/types.hpp"

using sat::Lit;
using sat::Var;
using sat::VarHeap;

TEST(Lit, EncodingRoundTrips) {
    Lit a(3), b(3, true);
    EXPECT_EQ(a.var(), 3);
    EXPECT_FALSE(a.negative());
    EXPECT_TRUE(b.negative());
    EXPECT_EQ(~a, b);
    EXPECT_EQ(~~a, a);
    EXPECT_NE(a.index(), b.index());
    EXPECT_FALSE(Lit().defined());
}

TEST(Lit, Dimacs) {
    EXPECT_EQ(Lit::from_dimacs(1), Lit(0));
    EXPECT_EQ(Lit::from_dimacs(-5), Lit(4, true));
    EXPECT_EQ(Lit(4, true).to_dimacs(), -5);
    EXPECT_EQ(Lit(0).to_dimacs(), 1);
}

TEST(VarHeap, PopsInDecreasingActivity) {
    std::vector<double> act = {0.5, 3.0, 1.0, 2.0, 2.5};
    VarHeap h(act);
    for (Var v = 0; v < 5; ++v) h.insert(v);
    std::vector<Var> order;
    while (!h.empty()) order.push_back(h.pop_max());
    EXPECT_EQ(order, (std::vector<Var>{1, 4, 3, 2, 0}));
}

TEST(VarHeap, InsertIsIdempotentAndContains) {
    std::vector<double> act = {1, 2};
    VarHeap h(act);
    h.insert(0);
    h.insert(0);
    EXPECT_EQ(h.size(), 1u);
    EXPECT_TRUE(h.contains(0));
    EXPECT_FALSE(h.contains(1));
    h.pop_max();
    EXPECT_FALSE(h.contains(0));
}

TEST(VarHeap, IncreasedReorders) {
    std::vector<double> act = {1, 2, 3};
    VarHeap h(act);
    for (Var v = 0; v < 3; ++v) h.insert(v);
    act[0] = 10;
    h.increased(0);
    EXPECT_EQ(h.pop_max(), 0);
}

TEST(VarHeap, RandomisedAgainstSort) {
    std::mt19937 rng(7);
    std::vector<double> act(200);
    for (double& a : act) a = std::uniform_real_distribution<>(0, 1)(rng);
    VarHeap h(act);
    for (Var v = 0; v < 200; ++v) h.insert(v);
    for (int i = 0; i < 300; ++i) {
        Var v = rng() % 200;
        act[v] += 1;
        h.increased(v);
    }
    double prev = 1e18;
    while (!h.empty()) {
        double a = act[h.pop_max()];
        EXPECT_LE(a, prev);
        prev = a;
    }
}
