#include <gtest/gtest.h>

#include <sstream>

#include "scheme/interpreter.hpp"
#include "scheme/stack.hpp"

using namespace scheme;

namespace {

// Runs a program with the stdin/stdout contract; returns everything written.
std::string run(const std::string& src) {
  std::ostringstream out;
  Interpreter in;
  in.run(src, out);
  return out.str();
}

}  // namespace

TEST(Interpreter, EmptyProgram) { EXPECT_EQ(run(""), ""); }

TEST(Interpreter, SpecExamples) {
  EXPECT_EQ(run("(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))\n"
                "(fact 20)\n(display \"done\") (newline)\n'(1 \"two\" (3 . 4) #t)\n(cons 1 2)"),
            "2432902008176640000\ndone\n(1 \"two\" (3 . 4) #t)\n(1 . 2)\n");
  EXPECT_EQ(run("(display \"a\")(display (list 1 \"b\" 'c))(newline)(if #f #f)"
                "(list (if #f #f) car)(quotient 1 0)(display \"never\")"),
            "a(1 b c)\n(#<void> #<procedure>)\nerror: division-by-zero\n");
}

TEST(Interpreter, VoidResultsPrintNothing) {
  EXPECT_EQ(run("(define x 1) (set! x 2) (if #f #f) (cond (#f 1)) (display 1)"), "1");
}

TEST(Interpreter, Truthiness) {
  EXPECT_EQ(run("(if 0 'y 'n) (if '() 'y 'n) (if \"\" 'y 'n) (if #f 'y 'n)"), "y\ny\ny\nn\n");
}

TEST(Interpreter, Bignums) {
  EXPECT_EQ(run("(* 99999999999 99999999999)"), "9999999999800000000001\n");
  EXPECT_EQ(run("(+ 9223372036854775807 1)"), "9223372036854775808\n");
  EXPECT_EQ(run("(- -9223372036854775808 1)"), "-9223372036854775809\n");
  EXPECT_EQ(run("(- -9223372036854775808)"), "9223372036854775808\n");
  EXPECT_EQ(run("(quotient -9223372036854775808 -1)"), "9223372036854775808\n");
  EXPECT_EQ(run("(- (+ 9223372036854775807 1) 1)"), "9223372036854775807\n");
  EXPECT_EQ(run("(quotient (* 1000000000000 1000000000000) 1000000000000)"), "1000000000000\n");
  EXPECT_EQ(run("(remainder -7 2) (remainder 7 -2) (quotient -7 2) (quotient 7 -2)"), "-1\n1\n-3\n-3\n");
  EXPECT_EQ(run("(= (* 4294967296 4294967296) 18446744073709551616)"), "#t\n");
  EXPECT_EQ(run("(eq? 100000000000000000000 100000000000000000000)"), "#t\n");
  EXPECT_EQ(run("(number->string -123456789012345678901234567890)"), "\"-123456789012345678901234567890\"\n");
}

TEST(Interpreter, FactorialDigits) {
  EXPECT_EQ(run("(define (f n) (if (= n 0) 1 (* n (f (- n 1)))))"
                "(string-length (number->string (f 2000)))"),
            "5736\n");
}

TEST(Interpreter, Comparisons) {
  EXPECT_EQ(run("(< 1 2 3) (< 1 3 2) (>= 3 3 2) (= 1 1 1) (<= 1 1 2)"), "#t\n#f\n#t\n#t\n#t\n");
  EXPECT_EQ(run("(< 2 1 \"x\")"), "error: type-error\n");
}

TEST(Interpreter, EvaluationOrder) {
  EXPECT_EQ(run("(list (display 1) (display 2) (display 3))"), "123(#<void> #<void> #<void>)\n");
  EXPECT_EQ(run("((begin (display \"f\") car) (begin (display \"x\") '(1)))"), "fx1\n");
  EXPECT_EQ(run("(let ((a (display \"a\")) (b (display \"b\"))) 0)"), "ab0\n");
}

TEST(Interpreter, Closures) {
  EXPECT_EQ(run("(define (mk) (let ((n 0)) (lambda () (set! n (+ n 1)) n)))"
                "(define c (mk)) (c) (c) (define d (mk)) (d) (c)"),
            "1\n2\n1\n3\n");
}

TEST(Interpreter, InternalDefineLandsInInnermostFrame) {
  EXPECT_EQ(run("(define x 'outer)"
                "(define (f) (define x 'inner) x)"
                "(f) x"),
            "inner\nouter\n");
  EXPECT_EQ(run("(let* ((a 1) (g (lambda () b))) (define b 2) (g))"), "error: unbound-variable\n");
}

TEST(Interpreter, NamedLetScope) {
  EXPECT_EQ(run("(define loop 5) (let loop ((x loop)) x)"), "5\n");
  EXPECT_EQ(run("(let go ((x 1)) (procedure? go))"), "#t\n");
  EXPECT_EQ(run("(let lp ((x 1)) (set! lp 'r) (list x lp))"), "(1 r)\n");
  EXPECT_EQ(run("(let lp ((i 0)) i) lp"), "0\nerror: unbound-variable\n");
}

TEST(Interpreter, Letrec) {
  EXPECT_EQ(run("(letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1)))))"
                "         (odd? (lambda (n) (if (= n 0) #f (even? (- n 1))))))"
                "  (even? 100))"),
            "#t\n");
}

TEST(Interpreter, CondForms) {
  EXPECT_EQ(run("(cond (#f 1) (2))"), "2\n");
  EXPECT_EQ(run("(cond (#f 1) (else 3 4))"), "4\n");
  EXPECT_EQ(run("(list (cond (#f 1)))"), "(#<void>)\n");
}

TEST(Interpreter, AndOr) {
  EXPECT_EQ(run("(and) (or) (and 1 2) (and 1 #f 3) (or #f 2) (or #f #f)"), "#t\n#f\n2\n#f\n2\n#f\n");
}

TEST(Interpreter, VariadicLambdas) {
  EXPECT_EQ(run("((lambda args args) 1 2 3)"), "(1 2 3)\n");
  EXPECT_EQ(run("((lambda (a . r) r) 1 2 3)"), "(2 3)\n");
  EXPECT_EQ(run("((lambda (a . r) r) 1)"), "()\n");
  EXPECT_EQ(run("(define (f a b . r) (list a b r)) (f 1 2) (f 1 2 3 4)"), "(1 2 ())\n(1 2 (3 4))\n");
  EXPECT_EQ(run("((lambda (a b . r) r) 1)"), "error: arity-error\n");
}

TEST(Interpreter, Apply) {
  EXPECT_EQ(run("(apply + 1 2 '(3 4))"), "10\n");
  EXPECT_EQ(run("(apply + '())"), "0\n");
  EXPECT_EQ(run("(apply + 1 2)"), "error: type-error\n");
  EXPECT_EQ(run("(apply +)"), "error: arity-error\n");
  EXPECT_EQ(run("(apply apply (list + (list 1 2)))"), "3\n");
}

TEST(Interpreter, Equality) {
  EXPECT_EQ(run("(eq? 'a 'a) (eq? '() '()) (eq? (list 1) (list 1)) (equal? (list 1 \"a\") (list 1 \"a\"))"),
            "#t\n#t\n#f\n#t\n");
  EXPECT_EQ(run("(let ((p (list 1))) (eq? p p))"), "#t\n");
  EXPECT_EQ(run("(eq? (if #f #f) (if #f #f))"), "#t\n");
}

TEST(Interpreter, Strings) {
  EXPECT_EQ(run("(string-append) (string-append \"a\" \"bc\") (string-length \"hello\")"),
            "\"\"\n\"abc\"\n5\n");
  EXPECT_EQ(run("(symbol->string 'abc)"), "\"abc\"\n");
  EXPECT_EQ(run("(display \"a\\\"b\") (display '(\"x\" y))"), "a\"b(x y)");
}

TEST(Interpreter, ErrorCategories) {
  EXPECT_EQ(run("undefined"), "error: unbound-variable\n");
  EXPECT_EQ(run("(set! undefined 1)"), "error: unbound-variable\n");
  EXPECT_EQ(run("(car '())"), "error: type-error\n");
  EXPECT_EQ(run("(+ 1 \"a\")"), "error: type-error\n");
  EXPECT_EQ(run("(1 2)"), "error: type-error\n");
  EXPECT_EQ(run("((lambda (x) x))"), "error: arity-error\n");
  EXPECT_EQ(run("((lambda (x) x) 1 2)"), "error: arity-error\n");
  EXPECT_EQ(run("(car)"), "error: arity-error\n");
  EXPECT_EQ(run("(-)"), "error: arity-error\n");
  EXPECT_EQ(run("(= 1)"), "error: arity-error\n");
  EXPECT_EQ(run("(remainder 1 0)"), "error: division-by-zero\n");
  EXPECT_EQ(run("(error 'a \"b\" 3)"), "error: user-error\n");
}

TEST(Interpreter, ErrorKeepsOutputAndStops) {
  EXPECT_EQ(run("(display \"x\") (car 1) (display \"never\")"), "xerror: type-error\n");
  EXPECT_EQ(run("(car (display \"x\") (display \"y\"))"), "xyerror: arity-error\n");
  EXPECT_EQ(run("(set! nope (display \"e\"))"), "eerror: unbound-variable\n");
}

TEST(Interpreter, RunReportsResult) {
  Interpreter in;
  std::ostringstream out;
  RunResult ok = in.run("(+ 1 2)", out);
  EXPECT_TRUE(ok.ok);
  RunResult bad = in.run("(error)", out);
  EXPECT_FALSE(bad.ok);
  EXPECT_EQ(*bad.error, ErrorKind::UserError);
}

TEST(Interpreter, StatePersistsAcrossRuns) {
  Interpreter in;
  std::ostringstream out;
  in.run("(define x 41)", out);
  in.run("(+ x 1)", out);
  EXPECT_EQ(out.str(), "42\n");
}

TEST(Interpreter, EvalStringApi) {
  Interpreter in;
  Value v = in.eval_string("(define (sq x) (* x x)) (sq 12)");
  ASSERT_TRUE(v.is_fixnum());
  EXPECT_EQ(v.as_fixnum(), 144);
  EXPECT_THROW(in.eval_string("(car 1)"), SchemeError);
}

TEST(Interpreter, CustomPrimitive) {
  Interpreter in;
  in.define_primitive("twice", 1, 1, [](Interpreter&, Value* a, size_t) {
    return Value::integer(a[0].as_fixnum() * 2);
  });
  EXPECT_EQ(in.eval_string("(twice 21)").as_fixnum(), 42);
}

TEST(Interpreter, TailCallsRunInConstantStack) {
  // Small native stack: would overflow if tail calls nested.
  run_with_stack_size(256 * 1024, [] {
    EXPECT_EQ(run("(let loop ((i 0)) (if (= i 300000) i (loop (+ i 1))))"), "300000\n");
    EXPECT_EQ(run("(define (f i) (cond ((= i 300000) i) (else (f (+ i 1))))) (f 0)"), "300000\n");
    EXPECT_EQ(run("(define (f i) (or (= i 300000) (f (+ i 1)))) (f 0)"), "#t\n");
    EXPECT_EQ(run("(define (f i) (and #t (if (= i 300000) i (f (+ i 1))))) (f 0)"), "300000\n");
    EXPECT_EQ(run("(define (f i) (begin 1 (let ((j i)) (let* ((k j)) (letrec ((z 1) ) "
                  "(if (= k 300000) k (apply f (list (+ k 1))))))))) (f 0)"),
              "300000\n");
  });
}

TEST(Interpreter, DeepNonTailRecursion) {
  run_with_stack_size(kDefaultStackBytes, [] {
    EXPECT_EQ(run("(define (count n) (if (= n 0) 0 (+ 1 (count (- n 1))))) (count 10000)"), "10000\n");
  });
}

TEST(Interpreter, LongListsAreFreedIteratively) {
  run_with_stack_size(256 * 1024, [] {
    EXPECT_EQ(run("(define (build n acc) (if (= n 0) acc (build (- n 1) (cons n acc))))"
                  "(define big (build 500000 '()))"
                  "(set! big 0) 'ok"),
              "ok\n");
  });
}
