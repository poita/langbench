// Every diagnostic kind, with the exact position the specification requires.
#include <gtest/gtest.h>

#include "support.h"

using testsupport::diagnosticOf;
using testsupport::diagnosticOfMain;

namespace {

struct Case {
  const char* name;
  const char* body;      // body of module main
  const char* expected;  // "" = accepted
};

class DiagnosticTest : public ::testing::TestWithParam<Case> {};

TEST_P(DiagnosticTest, ReportsExactLine) {
  const Case& c = GetParam();
  EXPECT_EQ(diagnosticOfMain(c.body), c.expected) << c.name;
}

const Case kCases[] = {
    {"parse_error", "fn main( {}\n", "error: parse at 1:10"},
    {"parse_eof", "fn main() {", "error: parse at 1:12"},
    {"chain_comparison", "fn main() { let a = 1 < 2 < 3; }\n", "error: parse at 1:27"},
    {"reserved_name", "struct Int { x: Int }\nfn main() {}\n", "error: reserved-name at 1:8"},
    {"dup_fn", "fn f() {}\nfn f() {}\nfn main() {}\n", "error: dup-name at 2:4"},
    {"dup_variant", "enum A { X, Y }\nenum B { X }\nfn main() {}\n", "error: dup-name at 2:10"},
    {"unknown_module", "use nope;\nfn main() {}\n", "error: unknown-module at 1:5"},
    {"unknown_type", "fn f(x: Nope) {}\nfn main() {}\n", "error: unknown-type at 1:9"},
    {"unknown_trait", "fn f<T: Nope>(x: T) {}\nfn main() {}\n", "error: unknown-trait at 1:9"},
    {"arity_type", "struct P<T> { x: T }\nfn f(p: P) {}\nfn main() {}\n", "error: arity-type at 2:9"},
    {"bad_key_type", "fn f(m: #[Float: Int]) {}\nfn main() {}\n", "error: bad-key-type at 1:9"},
    {"self_outside", "fn f(x: Self) {}\nfn main() {}\n", "error: self-outside at 1:9"},
    {"builtin_trait_impl", "impl Eq for Int {}\nfn main() {}\n", "error: builtin-trait-impl at 1:1"},
    {"bad_impl_head", "trait T { fn f(self); }\nimpl T for [Int] { fn f(self) {} }\nfn main() {}\n",
     "error: bad-impl-head at 2:12"},
    {"unused_param", "trait T { fn f(self); }\nimpl<A> T for Int { fn f(self) {} }\nfn main() {}\n",
     "error: unused-param at 2:6"},
    {"dup_impl", "trait T { fn f(self); }\nimpl T for Int { fn f(self) {} }\nimpl T for Int { fn f(self) {} }\nfn main() {}\n",
     "error: dup-impl at 3:1"},
    {"missing_method", "trait T { fn f(self); }\nimpl T for Int {}\nfn main() {}\n", "error: missing-method at 2:1"},
    {"extra_method", "trait T { fn f(self); }\nimpl T for Int { fn f(self) {} fn g(self) {} }\nfn main() {}\n",
     "error: extra-method at 2:35"},
    {"sig_mismatch", "trait T { fn f(self) -> Int; }\nimpl T for Int { fn f(self) -> Str { \"\" } }\nfn main() {}\n",
     "error: sig-mismatch at 2:21"},
    {"no_main", "fn other() {}\n", "error: no-main at 1:1"},
    {"main_with_params", "fn main(x: Int) {}\n", "error: no-main at 1:1"},
    {"unknown_name", "fn main() { print(nope); }\n", "error: unknown-name at 1:19"},
    {"type_mismatch", "fn main() { let n: Int = 1; print(n + \"x\"); }\n", "error: type-mismatch at 1:39"},
    {"arity", "fn f(a: Int) {}\nfn main() { f(1, 2); }\n", "error: arity at 2:13"},
    {"not_callable", "fn main() { let x = 1; x(2); }\n", "error: not-callable at 1:24"},
    {"not_struct", "fn main() { let x = 1; print(showInt(x.f)); }\n", "error: not-struct at 1:38"},
    {"unknown_field", "struct S { a: Int }\nfn main() { let s = S.{ a: 1 }; print(showInt(s.b)); }\n", "error: unknown-field at 2:49"},
    {"missing_field", "struct S { a: Int, b: Int }\nfn main() { let s = S.{ a: 1 }; }\n", "error: missing-field at 2:21"},
    {"dup_field", "struct S { a: Int }\nfn main() { let s = S.{ a: 1, a: 2 }; }\n", "error: dup-field at 2:31"},
    {"not_indexable", "fn main() { let x = 1; print(showInt(x[0])); }\n", "error: not-indexable at 1:38"},
    {"not_iterable", "fn main() { for c in 'a' {} }\n", "error: not-iterable at 1:22"},
    {"no_method", "fn main() { 1.nope(); }\n", "error: no-method at 1:15"},
    {"not_eq", "fn main() { let f = |x: Int| x; print(showBool(f == f)); }\n", "error: not-eq at 1:48"},
    {"not_ord", "fn main() { print(showBool((1, 2) < (3, 4))); }\n", "error: not-ord at 1:28"},
    {"cannot_infer", "fn main() { var xs = []; }\n", "error: cannot-infer at 1:22"},
    {"non_exhaustive", "enum C { A, B }\nfn f(c: C) -> Int { match c { A -> 1 } }\nfn main() {}\n", "error: non-exhaustive at 2:21"},
    {"unreachable", "fn main() { match 3 { _ -> print(\"a\"), 1 -> print(\"b\") } }\n", "error: unreachable at 1:40"},
    {"missing_return", "fn f() -> Int { let x = 1; }\nfn main() {}\n", "error: missing-return at 1:1"},
    {"bad_value_ref", "fn main() { let f = print; }\n", "error: bad-value-ref at 1:21"},
    {"bad_pattern", "fn main() { match 1.5 { 1.5 -> print(\"x\"), _ -> print(\"y\") } }\n", "error: bad-pattern at 1:25"},
    {"refutable_pattern", "fn main() { let Some(x) = Some(1); }\n", "error: refutable-pattern at 1:17"},
    {"break_outside", "fn main() { break; }\n", "error: break-outside at 1:13"},
    {"assign_immutable", "fn main() { let x = 1; x = 2; }\n", "error: assign-immutable at 1:24"},
    {"assign_captured", "fn main() { var x = 1; let f = || { x = 2; }; }\n", "error: assign-captured at 1:37"},
    {"bad_target", "fn f() -> Int { 1 }\nfn main() { f() = 2; }\n", "error: bad-target at 2:13"},
    {"bad_arity_tuple", "fn f(t: (Int, Int, Int, Int, Int, Int, Int, Int, Int)) {}\nfn main() {}\n", "error: bad-arity at 1:9"},
    {"if_statement_continues_as_call", "fn f() {}\nfn main() {\n    if true { f() } else { f() }\n    (1, 2);\n}\n", "error: not-callable at 3:5"},
    {"accepted", "fn main() { print(\"ok\"); }\n", ""},
};

INSTANTIATE_TEST_SUITE_P(Kinds, DiagnosticTest, ::testing::ValuesIn(kCases),
                         [](const ::testing::TestParamInfo<Case>& i) { return std::string(i.param.name); });

}  // namespace

TEST(DiagnosticOrder, EarlierPassWins) {
  // A parse error in a later module beats a type error in an earlier one.
  EXPECT_EQ(diagnosticOf("@module main\nfn main() { let x: Int = \"s\"; }\n@module other\nfn f( {\n}\n"),
            "error: parse at 1:7");
  // A lexical error in a later module beats a parse error in an earlier one.
  EXPECT_EQ(diagnosticOf("@module main\nfn main( {\n@module other\nlet x = #;\n"), "error: bad-token at 1:9");
}

TEST(DiagnosticOrder, ModuleStreamErrorsUseWholeInputLines) {
  EXPECT_EQ(diagnosticOf("@module a\nfn main() {}\n@module a\n"), "error: dup-module at 3:1");
  EXPECT_EQ(diagnosticOf("@module main\nfn main() {}\n@oops\n"), "error: bad-module at 3:1");
}

TEST(DiagnosticOrder, BodiesAreCheckedInSourceOrder) {
  EXPECT_EQ(diagnosticOfMain("fn a() { break; }\nfn main() { let x: Int = \"s\"; }\n"), "error: break-outside at 1:10");
}

TEST(Visibility, PrivateItemsAreNotPublic) {
  EXPECT_EQ(diagnosticOf("@module main\nuse m;\nfn main() { m::secret(); }\n@module m\nfn secret() {}\n"),
            "error: not-public at 2:16");
  EXPECT_EQ(diagnosticOf("@module main\nuse m;\nfn main() { m::open(); }\n@module m\npub fn open() {}\n"), "");
}
