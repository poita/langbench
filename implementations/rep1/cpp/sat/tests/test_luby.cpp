#include <gtest/gtest.h>

#include <vector>

#include "sat/luby.hpp"

TEST(Luby, BaseTwoPrefix) {
  std::vector<double> expected = {1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8};
  for (std::size_t i = 0; i < expected.size(); ++i)
    EXPECT_EQ(sat::luby(2.0, static_cast<int>(i)), expected[i]) << "i=" << i;
}

TEST(Luby, OtherBase) {
  EXPECT_EQ(sat::luby(3.0, 2), 3.0);
  EXPECT_EQ(sat::luby(3.0, 6), 9.0);
}
