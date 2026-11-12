#include <gtest/gtest.h>

#include <map>

#include "spreadsheet/evaluator.h"
#include "spreadsheet/parser.h"

using namespace spreadsheet;

namespace {

class MapCells : public CellLookup {
 public:
  void set(const char* name, Value v) { values_[parse_cell_ref(name)->key()] = std::move(v); }
  const Value& value_at(CellRef ref) const override {
    auto it = values_.find(ref.key());
    return it == values_.end() ? empty_ : it->second;
  }

 private:
  std::map<std::uint32_t, Value> values_;
  Value empty_;
};

std::string eval(const char* formula, const MapCells& cells = MapCells()) {
  return evaluate(parse_formula(formula), cells).display();
}

}  // namespace

TEST(Evaluator, Arithmetic) {
  EXPECT_EQ(eval("1+2*3"), "7");
  EXPECT_EQ(eval("(1+2)*3"), "9");
  EXPECT_EQ(eval("-2*3-4"), "-10");
  EXPECT_EQ(eval("2*-3"), "-6");
  EXPECT_EQ(eval("--5"), "5");
  EXPECT_EQ(eval("1/3"), "0.3333333333");
  EXPECT_EQ(eval("2/3*3"), "2");
}

TEST(Evaluator, ErrorsFromArithmetic) {
  EXPECT_EQ(eval("1/0"), "#DIV/0!");
  EXPECT_EQ(eval("1/-0"), "#DIV/0!");
  EXPECT_EQ(eval("\"a\"+1"), "#VALUE!");
  EXPECT_EQ(eval("\"5\"+1"), "#VALUE!");
  EXPECT_EQ(eval("-\"a\""), "#VALUE!");
}

TEST(Evaluator, OverflowIsValueError) {
  EXPECT_EQ(eval("100000000000000000000000000000000000000000000000000*100000000000000000000000000000000000000000000000000*100000000000000000000000000000000000000000000000000*100000000000000000000000000000000000000000000000000*100000000000000000000000000000000000000000000000000*100000000000000000000000000000000000000000000000000*100000000000000000000000000000000000000000000000000"), "#VALUE!");
}

TEST(Evaluator, FirstProblemInEvaluationOrderWins) {
  EXPECT_EQ(eval("1/0+\"a\""), "#DIV/0!");
  EXPECT_EQ(eval("\"a\"+1/0"), "#VALUE!");
  MapCells c;
  c.set("A1", Value::error(ErrorCode::Ref));
  EXPECT_EQ(eval("\"a\"+A1", c), "#VALUE!");
  EXPECT_EQ(eval("A1+\"a\"", c), "#REF!");
}

TEST(Evaluator, Concatenation) {
  EXPECT_EQ(eval("1+2&3"), "33");
  EXPECT_EQ(eval("\"a\"&1.5&\"b\""), "a1.5b");
  EXPECT_EQ(eval("1/3&\"\""), "0.3333333333");
}

TEST(Evaluator, EmptyCells) {
  MapCells c;
  EXPECT_EQ(eval("Z1", c), "0");
  EXPECT_EQ(eval("(Z1)&\"x\"", c), "x");
  EXPECT_EQ(eval("IF(1,Z1,7)&\"x\"", c), "x");
  EXPECT_EQ(eval("(Z1)=\"\"", c), "1");
  EXPECT_EQ(eval("Z1=0", c), "1");
  EXPECT_EQ(eval("Z1=Z2", c), "1");
  EXPECT_EQ(eval("COUNT((Z1))", c), "0");
  EXPECT_EQ(eval("-Z1&\"x\"", c), "0x");
  EXPECT_EQ(eval("Z1+1", c), "1");
  EXPECT_EQ(eval("IF(Z1,1,2)", c), "2");
}

TEST(Evaluator, Comparisons) {
  EXPECT_EQ(eval("1<2"), "1");
  EXPECT_EQ(eval("2<=2"), "1");
  EXPECT_EQ(eval("2<>2"), "0");
  EXPECT_EQ(eval("\"a\"<\"b\""), "1");
  EXPECT_EQ(eval("\"B\"<\"a\""), "1");  // case-sensitive, code point order
  EXPECT_EQ(eval("\"ab\">\"a\""), "1");  // prefix sorts first
  EXPECT_EQ(eval("1=\"1\""), "0");
  EXPECT_EQ(eval("1<>\"1\""), "1");
  EXPECT_EQ(eval("1<\"1\""), "#VALUE!");
  EXPECT_EQ(eval("\"1\">=1"), "#VALUE!");
}

TEST(Evaluator, StringComparisonIsByCodePoint) {
  // U+1F600 sorts after U+FF5A by code point (UTF-8 bytes).
  EXPECT_EQ(eval("\"\xF0\x9F\x98\x80\">\"\xEF\xBD\x9A\""), "1");
}

TEST(Evaluator, IfEvaluatesOnlySelectedBranch) {
  EXPECT_EQ(eval("IF(1,5,1/0)"), "5");
  EXPECT_EQ(eval("IF(0,1/0,6)"), "6");
  EXPECT_EQ(eval("IF(\"a\",1,2)"), "#VALUE!");
  EXPECT_EQ(eval("IF(0,AAA1,2)"), "#REF!");  // invalid reference anywhere
  EXPECT_EQ(eval("IF(1<2,\"yes\",\"no\")"), "yes");
}

TEST(Evaluator, Aggregates) {
  MapCells c;
  c.set("B1", Value::number(3));
  c.set("B2", Value::number(4.5));
  c.set("B3", Value::string("x"));
  EXPECT_EQ(eval("SUM(B1:B3)", c), "7.5");
  EXPECT_EQ(eval("AVG(B1:B3)", c), "3.75");
  EXPECT_EQ(eval("COUNT(B1:B3)", c), "2");
  EXPECT_EQ(eval("MIN(B1:B3, 1)", c), "1");
  EXPECT_EQ(eval("MAX(B3:B1)", c), "4.5");
  EXPECT_EQ(eval("SUM(B1:B3, B1, 2*2)", c), "14.5");
  EXPECT_EQ(eval("SUM(Q1:Q3)", c), "0");
  EXPECT_EQ(eval("MIN(Q1:Q3)", c), "0");
  EXPECT_EQ(eval("AVG(Q1:Q3)", c), "#DIV/0!");
  EXPECT_EQ(eval("SUM(\"a\")", c), "#VALUE!");
  c.set("B4", Value::error(ErrorCode::Cycle));
  EXPECT_EQ(eval("SUM(B1:B4)", c), "#CYCLE!");
}

TEST(Evaluator, InvalidReferenceYieldsRefError) {
  EXPECT_EQ(eval("A0+1"), "#REF!");
  EXPECT_EQ(eval("SUM(A1:A10000)"), "#REF!");
}
