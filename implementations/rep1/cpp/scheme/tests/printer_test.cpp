#include <gtest/gtest.h>

#include "scheme/interpreter.hpp"
#include "scheme/printer.hpp"

using namespace scheme;

TEST(Printer, WriteVersusDisplay) {
  Interpreter in;
  Value v = in.eval_string("(list \"a\\\"b\" 'c (cons 1 2) \"x\\ny\")");
  EXPECT_EQ(write_string(v), "(\"a\\\"b\" c (1 . 2) \"x\\ny\")");
  EXPECT_EQ(display_string(v), "(a\"b c (1 . 2) x\ny)");
}

TEST(Printer, SpecialValues) {
  Interpreter in;
  EXPECT_EQ(write_string(Value()), "#<void>");
  EXPECT_EQ(write_string(Value::null()), "()");
  EXPECT_EQ(write_string(in.eval_string("car")), "#<procedure>");
  EXPECT_EQ(write_string(in.eval_string("(lambda (x) x)")), "#<procedure>");
  EXPECT_EQ(write_string(in.eval_string("(list (if #f #f))")), "(#<void>)");
}

TEST(Printer, ImproperAndNested) {
  Interpreter in;
  EXPECT_EQ(write_string(in.eval_string("'(1 2 . 3)")), "(1 2 . 3)");
  EXPECT_EQ(write_string(in.eval_string("''a")), "(quote a)");
}

TEST(Printer, LongListDoesNotRecurseOnCdr) {
  Interpreter in;
  Value v = in.eval_string(
      "(define (iota n acc) (if (= n 0) acc (iota (- n 1) (cons n acc)))) (iota 200000 '())");
  std::string s = write_string(v);
  EXPECT_EQ(s.substr(0, 10), "(1 2 3 4 5");
}
