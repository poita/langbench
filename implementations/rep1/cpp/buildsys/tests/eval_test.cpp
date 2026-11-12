#include <gtest/gtest.h>

#include "support.hpp"

using namespace kiln;
using testing_support::eval_error;
using testing_support::eval_text;
using testing_support::workspace;

TEST(Expr, ArithmeticAndPrecedence) {
  EXPECT_EQ(eval_text("1 + 2 * 3"), "7");
  EXPECT_EQ(eval_text("(1 + 2) * 3"), "9");
  EXPECT_EQ(eval_text("10 - 4 - 3"), "3");
  EXPECT_EQ(eval_text("-7 / 2"), "-3");
  EXPECT_EQ(eval_text("-7 % 3"), "-1");
  EXPECT_EQ(eval_text("7 % -3"), "1");
  EXPECT_EQ(eval_text("- -3"), "3");
  EXPECT_EQ(eval_text("9223372036854775807 + 1"), "-9223372036854775808");
  EXPECT_EQ(eval_text("1 / 0"), "E_DIV_ZERO");
  EXPECT_EQ(eval_text("1 % 0"), "E_DIV_ZERO");
}

TEST(Expr, ComparisonUsesTheTotalOrder) {
  EXPECT_EQ(eval_text("1 < \"a\""), "true");
  EXPECT_EQ(eval_text("true < 0"), "true");
  EXPECT_EQ(eval_text("[1, 2] < [1, 3]"), "true");
  EXPECT_EQ(eval_text("\"abc\" == \"abc\""), "true");
  EXPECT_EQ(eval_text("1 == true"), "false");
  EXPECT_EQ(eval_text("[[1], \"a\"] == [[1], \"a\"]"), "true");
}

TEST(Expr, OperatorTypeErrors) {
  EXPECT_EQ(eval_text("\"a\" + [1]"), "E_TYPE operator +: expected int, got str");
  EXPECT_EQ(eval_text("1 + \"a\""), "E_TYPE operator +: expected int, got str");
  EXPECT_EQ(eval_text("1 ~ 2"), "E_TYPE operator ~: expected str, got int");
  EXPECT_EQ(eval_text("1 ++ [2]"), "E_TYPE operator ++: expected list, got int");
  EXPECT_EQ(eval_text("!1"), "E_TYPE operator !: expected bool, got int");
  EXPECT_EQ(eval_text("-\"a\""), "E_TYPE operator -: expected int, got str");
  EXPECT_EQ(eval_text("1 || true"), "E_TYPE operator ||: expected bool, got int");
}

TEST(Expr, ShortCircuit) {
  EXPECT_EQ(eval_text("true || missing"), "true");
  EXPECT_EQ(eval_text("false && missing"), "false");
  EXPECT_EQ(eval_text("false || missing"), "E_UNKNOWN_VAR missing");
  EXPECT_EQ(eval_text("false || 1"), "E_TYPE operator ||: expected bool, got int");
}

TEST(Expr, StringsAndListsConcatenate) {
  EXPECT_EQ(eval_text("\"a\" ~ \"b\" ~ \"c\""), "abc");
  EXPECT_EQ(eval_text("join([1] ++ [2] ++ [3], \"-\")"), "1-2-3");
}

TEST(Expr, Indexing) {
  EXPECT_EQ(eval_text("[\"a\", \"b\", \"c\"][-1]"), "c");
  EXPECT_EQ(eval_text("\"hello\"[1]"), "e");
  EXPECT_EQ(eval_text("[1][1]"), "E_ARG fn index: out of range");
  EXPECT_EQ(eval_text("\"\"[0]"), "E_ARG fn index: out of range");
  EXPECT_EQ(eval_text("[1][\"a\"]"), "E_TYPE index: expected int, got str");
  EXPECT_EQ(eval_text("5[\"a\"]"), "E_TYPE index: expected int, got str");
  EXPECT_EQ(eval_text("5[0]"), "E_TYPE index target: expected str|list, got int");
}

TEST(Expr, Pipes) {
  EXPECT_EQ(eval_text("\"abc\" |> upper"), "ABC");
  EXPECT_EQ(eval_text("[3, 1, 2] |> sort |> join(\",\")"), "1,2,3");
  EXPECT_EQ(eval_text("\"a,b\" |> split(\",\") |> len"), "2");
}

TEST(Interpolation, FormatsEachType) {
  EXPECT_EQ(eval_text("\"{1 + 1}|{true}|{\"s\"}|{-5}\""), "2|true|s|-5");
  EXPECT_EQ(eval_text("\"{{x}}\""), "{x}");
  EXPECT_EQ(eval_text("\"{[1]}\""), "E_INTERP list");
  EXPECT_EQ(eval_text("'a\\n{x}'"), "a\\n{x}");
  EXPECT_EQ(eval_text("'it''s'"), "it's");
  EXPECT_EQ(eval_text("\"{join([\"a\", \"b\"], \", \")}\""), "a, b");
}

TEST(Builtins, StringFunctions) {
  EXPECT_EQ(eval_text("upper(\"aBc1\")"), "ABC1");
  EXPECT_EQ(eval_text("lower(\"aBc1\")"), "abc1");
  EXPECT_EQ(eval_text("\"[\" ~ trim(\" \\t\\n x y \\r\") ~ \"]\""), "[x y]");
  EXPECT_EQ(eval_text("replace(\"aaa\", \"aa\", \"b\")"), "ba");
  EXPECT_EQ(eval_text("replace(\"a\", \"\", \"b\")"), "E_ARG fn replace: empty pattern");
  EXPECT_EQ(eval_text("starts_with(\"abc\", \"\")"), "true");
  EXPECT_EQ(eval_text("ends_with(\"abc\", \"bc\")"), "true");
  EXPECT_EQ(eval_text("contains(\"abc\", \"d\")"), "false");
  EXPECT_EQ(eval_text("substr(\"abcdef\", 1, 3)"), "bcd");
  EXPECT_EQ(eval_text("substr(\"abcdef\", -2, 5)"), "ef");
  EXPECT_EQ(eval_text("\"[\" ~ substr(\"abcdef\", 10, 2) ~ \"]\""), "[]");
  EXPECT_EQ(eval_text("\"[\" ~ substr(\"abcdef\", 2, -1) ~ \"]\""), "[]");
  EXPECT_EQ(eval_text("join(split(\"a,,b\", \",\"), \"|\")"), "a||b");
  EXPECT_EQ(eval_text("len(split(\"\", \",\"))"), "1");
  EXPECT_EQ(eval_text("split(\"a\", \"\")"), "E_ARG fn split: empty separator");
  EXPECT_EQ(eval_text("len(\"\xc3\xbc\")"), "2");  // bytes, not code points
  EXPECT_EQ(eval_text("str(true) ~ str(12) ~ str(\"s\")"), "true12s");
  EXPECT_EQ(eval_text("int(\"-007\")"), "-7");
  EXPECT_EQ(eval_text("int(\"+7\")"), "E_ARG fn int: bad integer");
  EXPECT_EQ(eval_text("int(\"\")"), "E_ARG fn int: bad integer");
  EXPECT_EQ(eval_text("int(\"9223372036854775808\")"), "E_ARG fn int: bad integer");
  EXPECT_EQ(eval_text("int(\"-9223372036854775808\")"), "-9223372036854775808");
}

TEST(Builtins, PathFunctions) {
  EXPECT_EQ(eval_text("dirname(\"a/b/c.txt\")"), "a/b");
  EXPECT_EQ(eval_text("\"[\" ~ dirname(\"c.txt\") ~ \"]\""), "[]");
  EXPECT_EQ(eval_text("basename(\"a/b/c.txt\")"), "c.txt");
  EXPECT_EQ(eval_text("stem(\"src/a.b.txt\")"), "a.b");
  EXPECT_EQ(eval_text("ext(\"src/a.b.txt\")"), ".txt");
  EXPECT_EQ(eval_text("stem(\"src/.hidden\")"), ".hidden");
  EXPECT_EQ(eval_text("\"[\" ~ ext(\"src/.hidden\") ~ \"]\""), "[]");
  EXPECT_EQ(eval_text("ext(\"src/x.\")"), ".");
  EXPECT_EQ(eval_text("stem(\"src/x.\")"), "x");
  EXPECT_EQ(eval_text("pathjoin(\"out\", \"\", \"a.txt\")"), "out/a.txt");
  EXPECT_EQ(eval_text("pathjoin(\"out/\")"), "out/");
  EXPECT_EQ(eval_text("pathjoin()"), "E_ARITY fn pathjoin: expected 1-8, got 0");
}

TEST(Builtins, ListFunctions) {
  EXPECT_EQ(eval_text("join(map([\"a\", \"b\"], \"out/%.o\"), \" \")"), "out/a.o out/b.o");
  EXPECT_EQ(eval_text("join(map([\"a\"], \"100%%-%\"), \"\")"), "100%-a");
  EXPECT_EQ(eval_text("map([1], \"%\")"), "E_TYPE fn map element 0: expected str, got int");
  EXPECT_EQ(eval_text("join(filter([\"a.txt\", \"b.md\"], \"*.txt\"), \",\")"), "a.txt");
  EXPECT_EQ(eval_text("join(reject([\"a.txt\", \"b.md\"], \"*.txt\"), \",\")"), "b.md");
  EXPECT_EQ(eval_text("filter([1], \"\")"), "E_ARG fn filter: bad pattern");
  EXPECT_EQ(eval_text("reject([\"a\", 2], \"*\")"), "E_TYPE fn reject element 1: expected str, got int");
  EXPECT_EQ(eval_text("join(sort([\"b\", \"a\", \"c\"]), \"\")"), "abc");
  EXPECT_EQ(eval_text("join(uniq([1, 2, 1, 3, 2]), \",\")"), "1,2,3");
  EXPECT_EQ(eval_text("join(reverse([1, 2, 3]), \",\")"), "3,2,1");
  EXPECT_EQ(eval_text("first([])"), "E_ARG fn first: empty list");
  EXPECT_EQ(eval_text("last([1, 2])"), "2");
  EXPECT_EQ(eval_text("join(slice([1, 2, 3, 4], -2, 5), \",\")"), "3,4");
  EXPECT_EQ(eval_text("has([[1], 2], [1])"), "true");
  EXPECT_EQ(eval_text("indexof([\"a\", \"b\"], \"b\")"), "1");
  EXPECT_EQ(eval_text("indexof([\"a\"], \"z\")"), "-1");
  EXPECT_EQ(eval_text("join(range(3), \",\")"), "0,1,2");
  EXPECT_EQ(eval_text("range(-1)"), "E_ARG fn range: negative");
  EXPECT_EQ(eval_text("sum([1, 2, 3])"), "6");
  EXPECT_EQ(eval_text("sum([1, \"a\"])"), "E_TYPE fn sum element 1: expected int, got str");
  EXPECT_EQ(eval_text("len(flatten([[1, 2], 3, [4]]))"), "4");
  EXPECT_EQ(eval_text("len(zip([1, 2, 3], [\"a\", \"b\"]))"), "2");
  EXPECT_EQ(eval_text("join([1, [2]], \",\")"), "E_TYPE fn join element 1: expected str|int, got list");
  EXPECT_EQ(eval_text("is_list([]) && is_str(\"\") && is_int(1) && is_bool(false)"), "true");
}

TEST(Builtins, CallOrderFixesTheReportedError) {
  EXPECT_EQ(eval_text("nope(undefined)"), "E_UNKNOWN_FUNC nope");
  EXPECT_EQ(eval_text("upper(undefined, 2)"), "E_UNKNOWN_VAR undefined");
  EXPECT_EQ(eval_text("upper(1, 2)"), "E_ARITY fn upper: expected 1, got 2");
  EXPECT_EQ(eval_text("upper(1)"), "E_TYPE fn upper argument 1: expected str, got int");
  EXPECT_EQ(eval_text("len(1)"), "E_TYPE fn len argument 1: expected str|list, got int");
  EXPECT_EQ(eval_text("str([])"), "E_TYPE fn str argument 1: expected str|int|bool, got list");
  EXPECT_EQ(eval_text("substr(\"a\", \"b\", 1)"), "E_TYPE fn substr argument 2: expected int, got str");
}

TEST(Builtins, GlobSeesOnlyEligibleFiles) {
  auto files = {std::pair<const char*, const char*>{"src/a.txt", ""}, {"src/sub/b.txt", ""},
                {"src/n.md", ""}, {"out/x.txt", ""}, {".kiln-state", ""}, {"top.txt", ""}};
  EXPECT_EQ(eval_text("join(glob(\"src/**/*.txt\"), \",\")", files), "src/a.txt,src/sub/b.txt");
  EXPECT_EQ(eval_text("join(glob(\"**\"), \",\")", files), "main.kiln,src/a.txt,src/n.md,src/sub/b.txt,top.txt");
  EXPECT_EQ(eval_text("join(glob(\"out/**\"), \",\")", files), "");
  EXPECT_EQ(eval_text("glob(\"src//a\")", files), "E_ARG fn glob: bad pattern");
}

TEST(Statements, LetSetAndScopes) {
  EXPECT_EQ(eval_error("let a = 1\nlet a = 2\n"), "E_REDEFINE a");
  EXPECT_EQ(eval_error("let a = missing\nlet a = 2\n"), "E_UNKNOWN_VAR missing");
  EXPECT_EQ(eval_error("set a = 1\n"), "E_SET_UNDEFINED a");
  EXPECT_EQ(eval_error("let a = 1\nwhen true {\n let a = 2\n set a = 3\n}\nabort \"{a}\"\n"), "E_ABORT 1");
  EXPECT_EQ(eval_error("let a = 1\nwhen true {\n set a = 3\n}\nabort \"{a}\"\n"), "E_ABORT 3");
  EXPECT_EQ(eval_error("each x in [1] {\n let x = 2\n}\n"), "E_REDEFINE x");
  EXPECT_EQ(eval_error("each i, x in [\"a\", \"b\"] {\n when i == 1 {\n abort x\n }\n}\n"), "E_ABORT b");
  EXPECT_EQ(eval_error("each x in 5 {\n}\n"), "E_TYPE each subject: expected list, got int");
  EXPECT_EQ(eval_error("when 1 {\n}\n"), "E_TYPE when condition: expected bool, got int");
  EXPECT_EQ(eval_error("when false {\n} elsewhen \"x\" {\n}\n"), "E_TYPE when condition: expected bool, got str");
  EXPECT_EQ(eval_error("when true {\n} elsewhen \"x\" {\n}\n"), "");
  EXPECT_EQ(eval_error("abort 1\n"), "E_TYPE abort message: expected str, got int");
}

TEST(Statements, IncludeSemantics) {
  EXPECT_EQ(eval_error("include \"nope.kiln\"\n"), "E_INCLUDE_MISSING nope.kiln");
  EXPECT_EQ(eval_error("include \"bad path\"\n"), "E_BAD_PATH bad path");
  EXPECT_EQ(eval_error("include 1\n"), "E_TYPE include path: expected str, got int");
  EXPECT_EQ(eval_error("include \"a.kiln\"\n", {{"a.kiln", "include \"main.kiln\"\n"}}), "E_INCLUDE_CYCLE main.kiln");
  EXPECT_EQ(eval_error("include \"a.kiln\"\ninclude \"a.kiln\"\n", {{"a.kiln", "let q = 1\n"}}), "E_REDEFINE q");
  EXPECT_EQ(eval_error("include \"a.kiln\"\nabort \"{q}\"\n", {{"a.kiln", "let q = 1\n"}}), "E_ABORT 1");
  EXPECT_EQ(eval_error("include \"a.kiln\"\n", {{"a.kiln", "let = 1\n"}}), "E_PARSE a.kiln:1");
  // Statements before an include have already run when its parse error is raised.
  EXPECT_EQ(eval_error("abort \"first\"\ninclude \"a.kiln\"\n", {{"a.kiln", "let = 1\n"}}), "E_ABORT first");
}

TEST(Rules, BindingAndDefaults) {
  const std::string rule = "rule r(a, b = a + 1) {\n abort \"{a},{b}\"\n}\n";
  EXPECT_EQ(eval_error(rule + "use r(1)\n"), "E_ABORT 1,2");
  EXPECT_EQ(eval_error(rule + "use r(1, 5)\n"), "E_ABORT 1,5");
  EXPECT_EQ(eval_error(rule + "use r(b = 7, a = 1)\n"), "E_ABORT 1,7");
  EXPECT_EQ(eval_error(rule + "use r(1, 2, 3)\n"), "E_ARITY rule r: expected 2, got 3");
  EXPECT_EQ(eval_error(rule + "use r(1, c = 2)\n"), "E_ARG rule r: unknown argument c");
  EXPECT_EQ(eval_error(rule + "use r(1, a = 2)\n"), "E_ARG rule r: duplicate argument a");
  EXPECT_EQ(eval_error(rule + "use r()\n"), "E_ARG rule r: missing argument a");
  EXPECT_EQ(eval_error("use nope(undefined)\n"), "E_UNKNOWN_RULE nope");
  EXPECT_EQ(eval_error("rule r() {\n}\nrule r() {\n}\n"), "E_REDEFINE r");
  EXPECT_EQ(eval_error("let r = 1\nrule r() {\n}\n"), "");
}

TEST(Rules, ScopeIsTheDefiningScopeByReference) {
  EXPECT_EQ(eval_error("let n = 1\nrule r() {\n abort \"{n}\"\n}\nset n = 2\nwhen true {\n let n = 3\n use r()\n}\n"),
            "E_ABORT 2");
  EXPECT_EQ(eval_error("rule r() {\n abort \"{late}\"\n}\nlet late = 9\nuse r()\n"), "E_ABORT 9");
}

TEST(Rules, RecursionLimit) {
  const std::string rec = "rule r(n) {\n use r(n + 1)\n}\n";
  EXPECT_EQ(eval_error(rec + "use r(0)\n"), "E_RULE_RECURSION r");
  const std::string deep = "rule r(n) {\n when n < 63 {\n  use r(n + 1)\n }\n}\n";
  EXPECT_EQ(eval_error(deep + "use r(0)\n"), "");  // exactly 64 nested instantiations
  const std::string deeper = "rule r(n) {\n when n < 64 {\n  use r(n + 1)\n }\n}\n";
  EXPECT_EQ(eval_error(deeper + "use r(0)\n"), "E_RULE_RECURSION r");
}

TEST(Steps, FieldErrors) {
  auto step = [](const std::string& body) { return "step {\n" + body + "}\n"; };
  EXPECT_EQ(eval_error(step(" out \"out/a\"\n")), "E_STEP_FIELD missing cmd");
  EXPECT_EQ(eval_error(step(" cmd write(\"x\")\n")), "E_STEP_FIELD missing out");
  EXPECT_EQ(eval_error(step(" out \"out/a\"\n cmd write(\"x\")\n cmd write(\"y\")\n")), "E_STEP_FIELD duplicate cmd");
  EXPECT_EQ(eval_error(step(" cost 1\n cost missing\n")), "E_STEP_FIELD duplicate cost");
  EXPECT_EQ(eval_error(step(" depfile \"out/d\"\n depfile 1\n")), "E_STEP_FIELD duplicate depfile");
  EXPECT_EQ(eval_error(step(" cost -1\n")), "E_ARG field cost: negative");
  EXPECT_EQ(eval_error(step(" cost \"1\"\n")), "E_TYPE field cost: expected int, got str");
  EXPECT_EQ(eval_error(step(" out 1\n")), "E_TYPE field out: expected strlist, got int");
  EXPECT_EQ(eval_error(step(" out [\"a\", 2]\n")), "E_TYPE field out: expected strlist, got int");
  EXPECT_EQ(eval_error(step(" cmd nope()\n")), "E_UNKNOWN_CMD nope");
  EXPECT_EQ(eval_error(step(" cmd grep()\n")), "E_ARITY cmd grep: expected 1, got 0");
  EXPECT_EQ(eval_error(step(" cmd grep(1)\n")), "E_TYPE cmd grep argument 1: expected str, got int");
  EXPECT_EQ(eval_error(step(" cmd indent(\"a\")\n")), "E_TYPE cmd indent argument 1: expected int, got str");
}

TEST(Steps, ValidationAtClosingBrace) {
  auto step = [](const std::string& body) { return "step {\n" + body + "}\n"; };
  EXPECT_EQ(eval_error(step(" out \"a b\"\n cmd write(\"x\")\n")), "E_BAD_PATH a b");
  EXPECT_EQ(eval_error(step(" out \"src/a\"\n cmd write(\"x\")\n")), "E_OUTPUT_PATH src/a");
  EXPECT_EQ(eval_error(step(" out [\"out/a\", \"x/b\"]\n cmd write(\"x\")\n")), "E_OUTPUT_PATH x/b");
  EXPECT_EQ(eval_error(step(" out [\"out/a\", \"b b\"]\n cmd write(\"x\")\n")), "E_BAD_PATH b b");
  EXPECT_EQ(eval_error(step(" out \"out/a\"\n in \"@\"\n cmd copy()\n")), "E_BAD_PATH @");
  EXPECT_EQ(eval_error(step(" out \"out/a\"\n after \"a b\"\n cmd write(\"x\")\n")), "E_BAD_PATH a b");
  EXPECT_EQ(eval_error(step(" out \"out/a\"\n cmd copy()\n")), "E_CMD_SHAPE copy: expected inputs 1-1, got 0");
  EXPECT_EQ(eval_error(step(" out \"out/a\"\n in \"x\"\n cmd write(\"x\")\n")),
            "E_CMD_SHAPE write: expected inputs 0-0, got 1");
  EXPECT_EQ(eval_error(step(" out \"out/a\"\n cmd concat()\n")), "E_CMD_SHAPE concat: expected inputs 1-N, got 0");
  EXPECT_EQ(eval_error(step(" out [\"out/a\", \"out/b\"]\n cmd write(\"x\")\n")),
            "E_CMD_SHAPE write: expected outputs 1, got 2");
  EXPECT_EQ(eval_error(step(" out \"out/a\"\n depfile \"out/d\"\n cmd write(\"x\")\n")),
            "E_CMD_SHAPE write: depfile not allowed");
  EXPECT_EQ(eval_error(step(" out \"out/a\"\n in \"x\"\n cmd preprocess()\n")), "E_CMD_SHAPE preprocess: depfile required");
  EXPECT_EQ(eval_error(step(" out \"out/a\"\n in \"x\"\n cmd replace(\"\", \"b\")\n")), "E_ARG cmd replace: empty pattern");
  EXPECT_EQ(eval_error(step(" out \"out/a\"\n in \"x\"\n cmd indent(-1)\n")), "E_ARG cmd indent: negative");
}

TEST(Steps, PhonyReferencesInInputsAreNotFileInputs) {
  // `copy` takes one file input; the phony reference does not count.
  EXPECT_EQ(eval_error("phony p = []\nstep {\n out \"out/a\"\n in [\"@p\", \"main.kiln\"]\n cmd copy()\n}\n"), "");
}

TEST(Phony, Declarations) {
  EXPECT_EQ(eval_error("phony a = []\nphony a = []\n"), "E_DUP_PHONY a");
  EXPECT_EQ(eval_error("phony a = 1\n"), "E_TYPE phony a: expected strlist, got int");
  EXPECT_EQ(eval_error("phony a = [\"x y\"]\n"), "E_BAD_PATH x y");
  EXPECT_EQ(eval_error("phony a = []\nphony a = [\"x y\"]\n"), "E_BAD_PATH x y");
}

TEST(Default, Typing) {
  EXPECT_EQ(eval_error("default 1\n"), "E_TYPE default: expected strlist, got int");
  EXPECT_EQ(eval_error("default [\"a\", true]\n"), "E_TYPE default: expected strlist, got bool");
  EXPECT_EQ(eval_error("default \"a\"\ndefault [\"b\"]\n"), "");
}
