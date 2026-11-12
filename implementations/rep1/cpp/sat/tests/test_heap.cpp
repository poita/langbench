#include <gtest/gtest.h>

#include <algorithm>
#include <numeric>
#include <random>
#include <vector>

#include "sat/heap.hpp"

TEST(VarHeap, RemovesInDescendingActivity) {
  std::vector<double> act = {3.0, 9.0, 1.0, 7.0, 5.0};
  sat::VarHeap h(act);
  for (int v = 0; v < 5; ++v) h.insert(v);
  std::vector<int> out;
  while (!h.empty()) out.push_back(h.removeMax());
  EXPECT_EQ(out, (std::vector<int>{1, 3, 4, 0, 2}));
}

TEST(VarHeap, InsertIsIdempotentAndContains) {
  std::vector<double> act = {1.0, 2.0};
  sat::VarHeap h(act);
  h.insert(0);
  h.insert(0);
  EXPECT_EQ(h.size(), 1);
  EXPECT_TRUE(h.contains(0));
  EXPECT_FALSE(h.contains(1));
  h.removeMax();
  EXPECT_FALSE(h.contains(0));
}

TEST(VarHeap, IncreasedReorders) {
  std::vector<double> act = {1.0, 2.0, 3.0};
  sat::VarHeap h(act);
  for (int v = 0; v < 3; ++v) h.insert(v);
  EXPECT_EQ(h.top(), 2);
  act[0] = 10.0;
  h.increased(0);
  EXPECT_EQ(h.top(), 0);
}

TEST(VarHeap, RandomisedAgainstSort) {
  std::mt19937 rng(42);
  std::vector<double> act(200);
  for (double& a : act) a = std::uniform_real_distribution<>(0, 1)(rng);
  sat::VarHeap h(act);
  for (int v = 0; v < 200; ++v) h.insert(v);
  std::vector<int> expected(200);
  std::iota(expected.begin(), expected.end(), 0);
  std::sort(expected.begin(), expected.end(), [&](int a, int b) { return act[a] > act[b]; });
  for (int v : expected) EXPECT_EQ(h.removeMax(), v);
}
