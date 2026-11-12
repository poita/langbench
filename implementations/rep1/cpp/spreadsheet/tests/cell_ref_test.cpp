#include <gtest/gtest.h>

#include "spreadsheet/cell_ref.h"

using namespace spreadsheet;

TEST(CellRef, ParsesValidNames) {
  auto a1 = parse_cell_ref("A1");
  ASSERT_TRUE(a1);
  EXPECT_EQ(a1->col, 1);
  EXPECT_EQ(a1->row, 1);
  auto zz = parse_cell_ref("ZZ9999");
  ASSERT_TRUE(zz);
  EXPECT_EQ(zz->col, 702);
  EXPECT_EQ(zz->row, 9999);
  EXPECT_EQ(parse_cell_ref("AA10")->col, 27);
}

TEST(CellRef, RejectsInvalidNames) {
  for (const char* s : {"", "A", "1", "A0", "A01", "A10000", "AAA1", "a1", "A1B", "A-1", "A1 "}) {
    EXPECT_FALSE(parse_cell_ref(s)) << s;
  }
}

TEST(CellRef, RoundTripsThroughToString) {
  for (const char* s : {"A1", "Z26", "AA1", "AZ100", "ZZ9999", "BA5"}) {
    EXPECT_EQ(to_string(*parse_cell_ref(s)), s);
  }
}

TEST(CellRef, KeyOrdersRowMajor) {
  EXPECT_LT(*parse_cell_ref("ZZ1"), *parse_cell_ref("A2"));
  EXPECT_LT(*parse_cell_ref("A1"), *parse_cell_ref("B1"));
  EXPECT_LT(*parse_cell_ref("Z1"), *parse_cell_ref("AA1"));
}

TEST(CellRange, NormalisesCorners) {
  auto r = CellRange::spanning(*parse_cell_ref("B2"), *parse_cell_ref("A1"));
  EXPECT_EQ(to_string(r.first), "A1");
  EXPECT_EQ(to_string(r.last), "B2");
  EXPECT_EQ(r.cell_count(), 4u);
  auto m = CellRange::spanning(*parse_cell_ref("A3"), *parse_cell_ref("C1"));
  EXPECT_EQ(to_string(m.first), "A1");
  EXPECT_EQ(to_string(m.last), "C3");
}
