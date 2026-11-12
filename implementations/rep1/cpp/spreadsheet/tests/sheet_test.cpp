#include <gtest/gtest.h>

#include <string>

#include "spreadsheet/parser.h"
#include "spreadsheet/sheet.h"

using namespace spreadsheet;

namespace {
CellRef R(const char* name) { return *parse_cell_ref(name); }
}  // namespace

TEST(Sheet, EmptyCell) {
  Sheet s;
  EXPECT_TRUE(s.value(R("A1")).is_empty());
  EXPECT_EQ(s.display(R("A1")), "");
  EXPECT_EQ(s.size(), 0u);
}

TEST(Sheet, LiteralContent) {
  Sheet s;
  s.set_content(R("A1"), "007");
  s.set_content(R("A2"), "-0");
  s.set_content(R("A3"), "4.50");
  s.set_content(R("A4"), "\"hello world\"");
  s.set_content(R("A5"), "\"\"");
  EXPECT_EQ(s.display(R("A1")), "7");
  EXPECT_EQ(s.display(R("A2")), "0");
  EXPECT_EQ(s.display(R("A3")), "4.5");
  EXPECT_EQ(s.display(R("A4")), "hello world");
  EXPECT_TRUE(s.value(R("A5")).is_string());
  EXPECT_EQ(s.size(), 5u);
}

TEST(Sheet, MalformedContentLeavesSheetUnchanged) {
  Sheet s;
  s.set_content(R("A1"), "5");
  EXPECT_THROW(s.set_content(R("A1"), "abc"), ParseError);
  EXPECT_THROW(s.set_content(R("A1"), "=1+"), ParseError);
  EXPECT_THROW(s.set_content(R("A1"), "1."), ParseError);
  EXPECT_EQ(s.display(R("A1")), "5");
}

TEST(Sheet, FormulasFollowEdits) {
  Sheet s;
  s.set_number(R("A1"), 10);
  s.set_number(R("A2"), 32);
  s.set_formula(R("A3"), "A1+A2");
  EXPECT_EQ(s.display(R("A3")), "42");
  s.set_number(R("A1"), 5);
  EXPECT_EQ(s.display(R("A3")), "37");
  s.clear(R("A2"));
  EXPECT_EQ(s.display(R("A3")), "5");
}

TEST(Sheet, FormulaCreatedBeforeItsInputs) {
  Sheet s;
  s.set_formula(R("A1"), "B1*2");
  EXPECT_EQ(s.display(R("A1")), "0");
  s.set_number(R("B1"), 4);
  EXPECT_EQ(s.display(R("A1")), "8");
}

TEST(Sheet, TransitiveRecalculation) {
  Sheet s;
  s.set_number(R("A1"), 1);
  s.set_formula(R("A2"), "A1+1");
  s.set_formula(R("A3"), "A2+1");
  s.set_formula(R("B1"), "A3*10");
  s.set_number(R("A1"), 100);
  EXPECT_EQ(s.display(R("B1")), "1020");
}

TEST(Sheet, SelfReferenceIsCycle) {
  Sheet s;
  s.set_formula(R("A1"), "A1+1");
  EXPECT_EQ(s.display(R("A1")), "#CYCLE!");
  s.set_number(R("A1"), 1);
  EXPECT_EQ(s.display(R("A1")), "1");
}

TEST(Sheet, RangeContainingItselfIsCycle) {
  Sheet s;
  s.set_formula(R("A3"), "SUM(A1:A5)");
  EXPECT_EQ(s.display(R("A3")), "#CYCLE!");
}

TEST(Sheet, CycleCreatedAndBroken) {
  Sheet s;
  s.set_number(R("A1"), 10);
  s.set_number(R("A2"), 32);
  s.set_formula(R("A3"), "A1+A2");
  s.set_formula(R("A1"), "A3");
  EXPECT_EQ(s.display(R("A1")), "#CYCLE!");
  EXPECT_EQ(s.display(R("A3")), "#CYCLE!");
  s.set_number(R("A1"), 5);
  EXPECT_EQ(s.display(R("A3")), "37");
}

TEST(Sheet, ReadersOfCycleGetCycleUnlessMasked) {
  Sheet s;
  s.set_formula(R("A1"), "B1");
  s.set_formula(R("B1"), "A1");
  s.set_formula(R("C1"), "A1+1");
  s.set_formula(R("C2"), "IF(1,7,A1)");
  s.set_formula(R("C3"), "IF(0,7,A1)");
  EXPECT_EQ(s.display(R("C1")), "#CYCLE!");
  EXPECT_EQ(s.display(R("C2")), "7");  // static dependency, but not read
  EXPECT_EQ(s.display(R("C3")), "#CYCLE!");
  s.clear(R("B1"));
  EXPECT_EQ(s.display(R("A1")), "0");
  EXPECT_EQ(s.display(R("C1")), "1");
}

TEST(Sheet, ClearCellInsideCycleBreaksIt) {
  Sheet s;
  s.set_formula(R("A1"), "B1+1");
  s.set_formula(R("B1"), "C1+1");
  s.set_formula(R("C1"), "A1+1");
  EXPECT_EQ(s.display(R("B1")), "#CYCLE!");
  s.clear(R("C1"));
  EXPECT_EQ(s.display(R("B1")), "1");
  EXPECT_EQ(s.display(R("A1")), "2");
}

TEST(Sheet, InvalidReferenceHasNoDependencies) {
  Sheet s;
  s.set_formula(R("A1"), "A1+AAA1");  // would be a self-cycle if the ref were valid
  EXPECT_EQ(s.display(R("A1")), "#REF!");
}

TEST(Sheet, FormulaReplacedDropsOldDependencies) {
  Sheet s;
  s.set_number(R("A1"), 1);
  s.set_formula(R("B1"), "A1");
  s.set_number(R("C1"), 9);
  s.set_formula(R("B1"), "C1");
  s.set_number(R("A1"), 2);
  EXPECT_EQ(s.display(R("B1")), "9");
  s.set_formula(R("A1"), "B1");  // would be a cycle only via a stale edge to A1
  EXPECT_EQ(s.display(R("A1")), "9");
}

TEST(Sheet, RangesTrackTheirCells) {
  Sheet s;
  s.set_formula(R("C1"), "SUM(A1:B2)");
  s.set_number(R("B2"), 4);
  EXPECT_EQ(s.display(R("C1")), "4");
  s.set_string(R("A2"), "text");
  EXPECT_EQ(s.display(R("C1")), "4");
  s.set_formula(R("A1"), "1/0");
  EXPECT_EQ(s.display(R("C1")), "#DIV/0!");
}

TEST(Sheet, CellsAreListedRowMajor) {
  Sheet s;
  s.set_number(R("B2"), 1);
  s.set_number(R("A2"), 2);
  s.set_number(R("AA1"), 3);
  s.set_number(R("C1"), 4);
  s.set_string(R("Z1"), "");
  auto cells = s.cells();
  std::string order;
  for (auto& [ref, v] : cells) order += to_string(ref) + " ";
  EXPECT_EQ(order, "C1 Z1 AA1 A2 B2 ");
}

TEST(Sheet, ClearingMakesCellDisappear) {
  Sheet s;
  s.set_number(R("A1"), 1);
  s.clear(R("A1"));
  s.clear(R("B7"));  // never set
  EXPECT_EQ(s.size(), 0u);
  EXPECT_TRUE(s.cells().empty());
}

TEST(Sheet, DeepDependencyChain) {
  Sheet s;
  const int n = 9000;
  s.set_number(R("A1"), 1);
  for (int i = 2; i <= n; ++i) {
    s.set_formula(R(("A" + std::to_string(i)).c_str()), "A" + std::to_string(i - 1) + "+1");
  }
  EXPECT_EQ(s.display(R("A9000")), "9000");
  s.set_number(R("A1"), 10);
  EXPECT_EQ(s.display(R("A9000")), "9009");
  s.set_formula(R("A1"), "A9000");
  EXPECT_EQ(s.display(R("A5000")), "#CYCLE!");
  s.set_number(R("A1"), 0);
  EXPECT_EQ(s.display(R("A5000")), "4999");
}

TEST(Sheet, MoveConstruct) {
  Sheet a;
  a.set_number(R("A1"), 3);
  Sheet b(std::move(a));
  EXPECT_EQ(b.display(R("A1")), "3");
}
