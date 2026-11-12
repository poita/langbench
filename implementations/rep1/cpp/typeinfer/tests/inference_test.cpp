#include <gtest/gtest.h>

#include "typeinfer/session.hpp"

using namespace typeinfer;

namespace {
// Checks `src` in a fresh session and returns the report lines.
std::vector<std::string> run(std::string_view src) {
    Session s;
    std::vector<std::string> out;
    for (auto& r : s.check(src)) out.push_back(r.to_string());
    return out;
}
std::string one(std::string_view src) {
    auto v = run(src);
    EXPECT_EQ(v.size(), 1u);
    return v.empty() ? "" : v[0];
}
}  // namespace

TEST(Inference, Literals) {
    EXPECT_EQ(one("1;;"), "- : int");
    EXPECT_EQ(one("true;;"), "- : bool");
    EXPECT_EQ(one("();;"), "- : unit");
    EXPECT_EQ(one("[];;"), "- : 'a list");
}

TEST(Inference, Builtins) {
    EXPECT_EQ(one("map;;"), "- : ('a -> 'b) -> 'a list -> 'b list");
    EXPECT_EQ(one("fold;;"), "- : ('a -> 'b -> 'a) -> 'a -> 'b list -> 'a");
    EXPECT_EQ(one("fst;;"), "- : 'a * 'b -> 'a");
    EXPECT_EQ(one("length;;"), "- : 'a list -> int");
    EXPECT_EQ(one("not;;"), "- : bool -> bool");
}

TEST(Inference, Operators) {
    EXPECT_EQ(one("1 + 2 * 3;;"), "- : int");
    EXPECT_EQ(one("1 < 2;;"), "- : bool");
    EXPECT_EQ(one("true && false || true;;"), "- : bool");
    EXPECT_EQ(one("true = false;;"), "error: unify");
}

TEST(Inference, LetPolymorphismWithoutValueRestriction) {
    EXPECT_EQ(one("(let id = fun x -> x in let g = id id in (g 1, g true));;"), "- : int * bool");
}

TEST(Inference, LambdaBoundVariablesAreMonomorphic) {
    EXPECT_EQ(one("fun f -> (f 1, f true);;"), "error: unify");
}

TEST(Inference, LetRecIsMonomorphicInsideItsBody) {
    EXPECT_EQ(one("let rec bad x = bad 1 + bad true;;"), "error: unify");
    EXPECT_EQ(one("let rec len l = if null l then 0 else 1 + len (tl l);;"),
              "len : 'a list -> int");
}

TEST(Inference, LetDoesNotSeeItself) {
    EXPECT_EQ(one("let x = x + 1;;"), "error: unbound");
    EXPECT_EQ(run("let x = true;; let x = x && false;;"),
              (std::vector<std::string>{"x : bool", "x : bool"}));
}

TEST(Inference, OccursCheck) { EXPECT_EQ(one("fun x -> x x;;"), "error: occurs"); }

TEST(Inference, UnboundVariable) { EXPECT_EQ(one("nope;;"), "error: unbound"); }

TEST(Inference, ErrorKindOrder) {
    EXPECT_EQ(one("fun x -> if true then (x, 0) else ([x], true);;"), "error: occurs");
    EXPECT_EQ(one("true + undefined;;"), "error: unify");
    EXPECT_EQ(one("undefined + true;;"), "error: unbound");
    EXPECT_EQ(one("fun x -> (fun y -> y) x x;;"), "error: occurs");
}

TEST(Inference, FailedDeclarationAddsNothing) {
    EXPECT_EQ(run("let f = 1;; let f = f + true;; f;;"),
              (std::vector<std::string>{"f : int", "error: unify", "- : int"}));
}

TEST(Inference, ShadowingBuiltins) {
    EXPECT_EQ(run("let map = 3;; map;;"), (std::vector<std::string>{"map : int", "- : int"}));
}

TEST(Inference, ListsAndCons) {
    EXPECT_EQ(one("1 :: [true];;"), "error: unify");
    EXPECT_EQ(one("[fun x -> x; fun y -> 1];;"), "- : (int -> int) list");
    EXPECT_EQ(one("1 :: 2 :: [];;"), "- : int list");
}

TEST(Inference, Tuples) {
    EXPECT_EQ(one("(fun x -> x, 1);;"), "- : ('a -> 'a) * int");
    EXPECT_EQ(one("(1, 2, 3);;"), "- : int * int * int");
    EXPECT_EQ(one("fst (1, 2, 3);;"), "error: unify");
}

TEST(Inference, ChurchNumerals) {
    EXPECT_EQ(one("let succ n = fun f x -> f (n f x);;"),
              "succ : (('a -> 'b) -> 'c -> 'a) -> ('a -> 'b) -> 'c -> 'b");
}

TEST(Inference, NestedLetGeneralisation) {
    EXPECT_EQ(one("fun a b c -> let p = (a, b) in (fun x -> [x; c], p, fst p);;"),
              "- : 'a -> 'b -> 'c -> ('c -> 'c list) * ('a * 'b) * 'a");
}

TEST(Inference, GeneralisationRespectsEnvironment) {
    // y's type is tied to the lambda-bound x, so it must not be generalised.
    EXPECT_EQ(one("fun x -> let y = x in (y 1, y true);;"), "error: unify");
    EXPECT_EQ(one("fun x -> let y = x in y;;"), "- : 'a -> 'a");
}

TEST(Inference, FunWithManyParameters) {
    EXPECT_EQ(one("fun a b c -> a;;"), "- : 'a -> 'b -> 'c -> 'a");
}
