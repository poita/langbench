#include <gtest/gtest.h>

#include "test_util.hpp"

using namespace kiln;
using kiln::testing::evalError;
using kiln::testing::evalToString;

namespace {
// Evaluate an expression as the argument of a step's write() and report either
// the value or the error.
std::string ev(const std::string& expr, const std::string& prelude = "") {
  std::string err = evalError(prelude + "\nlet _r = " + expr + "\n");
  if (!err.empty()) return "ERR " + err;
  return evalToString("str(" + expr + ")", prelude);
}
}  // namespace

TEST(Builtins, StringFunctions) {
  EXPECT_EQ(ev("upper(\"abC\")"), "ABC");
  EXPECT_EQ(ev("lower(\"ABc\")"), "abc");
  EXPECT_EQ(ev("trim(\" \\t x y \\n\")"), "x y");
  EXPECT_EQ(ev("replace(\"aaa\", \"aa\", \"b\")"), "ba");
  EXPECT_EQ(ev("starts_with(\"abc\", \"\")"), "true");
  EXPECT_EQ(ev("ends_with(\"abc\", \"bc\")"), "true");
  EXPECT_EQ(ev("contains(\"abc\", \"d\")"), "false");
  EXPECT_EQ(ev("len(\"h\xc3\xa9\")"), "3");  // bytes, not code points
}

TEST(Builtins, Substr) {
  EXPECT_EQ(ev("substr(\"abcdef\", 1, 3)"), "bcd");
  EXPECT_EQ(ev("substr(\"abcdef\", -2, 5)"), "ef");
  EXPECT_EQ(ev("substr(\"abcdef\", 10, 2)"), "");
  EXPECT_EQ(ev("substr(\"abcdef\", 2, -1)"), "");
}

TEST(Builtins, SplitJoin) {
  EXPECT_EQ(ev("count(split(\"\", \",\"))"), "1");
  EXPECT_EQ(ev("join(split(\"a,,b\", \",\"), \"|\")"), "a||b");
  EXPECT_EQ(ev("split(\"a\", \"\")"), "ERR E_ARG fn split: empty separator");
  EXPECT_EQ(ev("join([1, \"a\"], \"-\")"), "1-a");
  EXPECT_EQ(ev("join([[1]], \"-\")"), "ERR E_TYPE fn join element 0: expected str|int, got list");
}


TEST(Builtins, IntConversion) {
  EXPECT_EQ(ev("str(int(\"-007\"))"), "-7");
  EXPECT_EQ(ev("int(\"+1\")"), "ERR E_ARG fn int: bad integer");
  EXPECT_EQ(ev("int(\"\")"), "ERR E_ARG fn int: bad integer");
  EXPECT_EQ(ev("int(\"9223372036854775808\")"), "ERR E_ARG fn int: bad integer");
  EXPECT_EQ(ev("str(int(\"9223372036854775807\"))"), "9223372036854775807");
  EXPECT_EQ(ev("str(int(\"-9223372036854775808\"))"), "-9223372036854775808");
}

TEST(Builtins, PathFunctions) {
  EXPECT_EQ(ev("dirname(\"a/b/c.txt\")"), "a/b");
  EXPECT_EQ(ev("dirname(\"c.txt\")"), "");
  EXPECT_EQ(ev("basename(\"a/b/c.txt\")"), "c.txt");
  EXPECT_EQ(ev("stem(\"src/a.b.txt\")"), "a.b");
  EXPECT_EQ(ev("ext(\"src/a.b.txt\")"), ".txt");
  EXPECT_EQ(ev("stem(\"src/.hidden\")"), ".hidden");
  EXPECT_EQ(ev("ext(\"src/.hidden\")"), "");
  EXPECT_EQ(ev("ext(\"src/x.\")"), ".");
  EXPECT_EQ(ev("pathjoin(\"out\", \"\", \"a.txt\")"), "out/a.txt");
  EXPECT_EQ(ev("pathjoin(\"out/\")"), "out/");
  EXPECT_EQ(ev("pathjoin()"), "ERR E_ARITY fn pathjoin: expected 1-8, got 0");
}

TEST(Builtins, MapFilterReject) {
  EXPECT_EQ(ev("join(map([\"a\", \"b\"], \"out/%.o\"), \" \")"), "out/a.o out/b.o");
  EXPECT_EQ(ev("join(map([\"a\"], \"100%%-%\"), \"\")"), "100%-a");
  EXPECT_EQ(ev("join(filter([\"a.c\", \"b.h\"], \"*.c\"), \",\")"), "a.c");
  EXPECT_EQ(ev("join(reject([\"a.c\", \"b.h\"], \"*.c\"), \",\")"), "b.h");
  EXPECT_EQ(ev("filter([1], \"\")"), "ERR E_ARG fn filter: bad pattern");
  EXPECT_EQ(ev("filter([1], \"*\")"), "ERR E_TYPE fn filter element 0: expected str, got int");
}

TEST(Builtins, ListFunctions) {
  EXPECT_EQ(ev("join(sort([3, 1, 2]), \",\")"), "1,2,3");
  EXPECT_EQ(ev("join(uniq([1, 2, 1, 3, 2]), \",\")"), "1,2,3");
  EXPECT_EQ(ev("join(reverse([1, 2, 3]), \",\")"), "3,2,1");
  EXPECT_EQ(ev("first([])"), "ERR E_ARG fn first: empty list");
  EXPECT_EQ(ev("last([])"), "ERR E_ARG fn last: empty list");
  EXPECT_EQ(ev("join(slice([1, 2, 3, 4], -2, 5), \",\")"), "3,4");
  EXPECT_EQ(ev("has([[1], 2], [1])"), "true");
  EXPECT_EQ(ev("indexof([1, 2, 3], 3)"), "2");
  EXPECT_EQ(ev("indexof([1, 2, 3], \"3\")"), "-1");
  EXPECT_EQ(ev("range(-1)"), "ERR E_ARG fn range: negative");
  EXPECT_EQ(ev("str(sum([1, 2, 3]))"), "6");
  EXPECT_EQ(ev("sum([1, \"a\"])"), "ERR E_TYPE fn sum element 1: expected int, got str");
  EXPECT_EQ(ev("count(flatten([[1, 2], 3, [[4]]]))"), "4");
  EXPECT_EQ(ev("count(zip([1, 2, 3], [\"a\"]))"), "1");
}

TEST(Builtins, CallOrder) {
  EXPECT_EQ(ev("nope(undefined)"), "ERR E_UNKNOWN_FUNC nope");
  EXPECT_EQ(ev("upper(undefined, 2)"), "ERR E_UNKNOWN_VAR undefined");
  EXPECT_EQ(ev("upper(\"a\", 2)"), "ERR E_ARITY fn upper: expected 1, got 2");
  EXPECT_EQ(ev("upper(1)"), "ERR E_TYPE fn upper argument 1: expected str, got int");
  EXPECT_EQ(ev("len(1)"), "ERR E_TYPE fn len argument 1: expected str|list, got int");
}

TEST(Builtins, Glob) {
  Vfs vfs = kiln::testing::makeVfs({{"main.kiln", "let g = glob(\"src/**/*.txt\")\n"
                                                    "step {\n out \"out/x\"\n cmd write(join(g, \",\"))\n}\n"},
                                    {"src/a.txt", ""},
                                    {"src/sub/b.txt", ""},
                                    {"src/c.md", ""},
                                    {"out/src/d.txt", ""}});
  BuildPlan plan = Evaluator(vfs).evaluate();
  EXPECT_EQ(plan.steps[0].call.args[0].asStr(), "src/a.txt,src/sub/b.txt");
}
