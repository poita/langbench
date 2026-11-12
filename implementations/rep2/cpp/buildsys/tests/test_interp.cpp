#include <gtest/gtest.h>

#include "test_util.hpp"

using namespace kiln;
using kiln::testing::evalError;
using kiln::testing::evalToString;

TEST(Interp, ArithmeticAndPrecedence) {
  EXPECT_EQ(evalToString("\"{1 + 2 * 3}\""), "7");
  EXPECT_EQ(evalToString("\"{(1 + 2) * 3}\""), "9");
  EXPECT_EQ(evalToString("\"{-7 / 2}|{-7 % 2}|{7 % -2}\""), "-3|-1|1");
  EXPECT_EQ(evalToString("\"{- -3}\""), "3");
  EXPECT_EQ(evalError("let x = 1 / 0\n"), "E_DIV_ZERO");
  EXPECT_EQ(evalError("let x = 1 % 0\n"), "E_DIV_ZERO");
}

TEST(Interp, OperatorTypeErrors) {
  EXPECT_EQ(evalError("let x = \"a\" + [1]\n"), "E_TYPE operator +: expected int, got str");
  EXPECT_EQ(evalError("let x = 1 ~ 2\n"), "E_TYPE operator ~: expected str, got int");
  EXPECT_EQ(evalError("let x = !1\n"), "E_TYPE operator !: expected bool, got int");
  EXPECT_EQ(evalError("let x = -\"a\"\n"), "E_TYPE operator -: expected int, got str");
  EXPECT_EQ(evalError("let x = 1 ++ [1]\n"), "E_TYPE operator ++: expected list, got int");
}

TEST(Interp, ShortCircuit) {
  EXPECT_EQ(evalError("let x = true || undefined\n"), "");
  EXPECT_EQ(evalError("let x = false && undefined\n"), "");
  EXPECT_EQ(evalError("let x = false || undefined\n"), "E_UNKNOWN_VAR undefined");
  EXPECT_EQ(evalError("let x = 1 || true\n"), "E_TYPE operator ||: expected bool, got int");
}

TEST(Interp, Comparison) {
  EXPECT_EQ(evalToString("\"{1 < 'a'}|{[1, 2] < [1, 3]}|{true < 0}\""), "true|true|true");
  EXPECT_EQ(evalToString("\"{1 == true}|{[1] == [1]}\""), "false|true");
}

TEST(Interp, IndexingAndInterpolation) {
  EXPECT_EQ(evalToString("\"{'abc'[-1]}{[1, 2][0]}\""), "c1");
  EXPECT_EQ(evalError("let x = [1][1]\n"), "E_ARG fn index: out of range");
  EXPECT_EQ(evalError("let x = 5[\"a\"]\n"), "E_TYPE index: expected int, got str");
  EXPECT_EQ(evalError("let x = 5[0]\n"), "E_TYPE index target: expected str|list, got int");
  EXPECT_EQ(evalError("let x = \"{[1]}\"\n"), "E_INTERP list");
  EXPECT_EQ(evalToString("\"{{literal}}\""), "{literal}");
  EXPECT_EQ(evalToString("'a\\nb{x}'"), "a\\nb{x}");
  EXPECT_EQ(evalToString("'it''s'"), "it's");
}

TEST(Interp, LetSetScoping) {
  EXPECT_EQ(evalError("let x = 1\nlet x = 2\n"), "E_REDEFINE x");
  EXPECT_EQ(evalError("set x = 1\n"), "E_SET_UNDEFINED x");
  EXPECT_EQ(evalError("let x = 1\nwhen true {\n let x = 2\n}\n"), "");  // shadowing
  EXPECT_EQ(evalError("let x = 1\nwhen true {\n set x = 2\n}\nlet y = 1 / (x - 2)\n"), "E_DIV_ZERO");
  EXPECT_EQ(evalError("let x = y\nlet y = 1\n"), "E_UNKNOWN_VAR y");
  EXPECT_EQ(evalError("let x = undefined\nlet x = 1\n"), "E_UNKNOWN_VAR undefined");
}

TEST(Interp, WhenElsewhenOtherwise) {
  EXPECT_EQ(evalError("when 1 {\n}\n"), "E_TYPE when condition: expected bool, got int");
  EXPECT_EQ(evalError("when true {\n} elsewhen 1 {\n}\n"), "");  // later conditions not evaluated
  EXPECT_EQ(evalError("when false {\n} elsewhen false {\n} otherwise {\n abort \"o\"\n}\n"), "E_ABORT o");
}

TEST(Interp, Each) {
  EXPECT_EQ(evalError("each x in 5 {\n}\n"), "E_TYPE each subject: expected list, got int");
  Vfs vfs = kiln::testing::makeVfs(
      {{"main.kiln", "let acc = []\neach i, x in [\"a\", \"b\"] {\n set acc = acc ++ [\"{i}{x}\"]\n}\n"
                     "step {\n out \"out/x\"\n cmd write(join(acc, \",\"))\n}\n"}});
  EXPECT_EQ(Evaluator(vfs).evaluate().steps[0].call.args[0].asStr(), "0a,1b");
}

TEST(Interp, IncludeSemantics) {
  Vfs vfs = kiln::testing::makeVfs(
      {{"main.kiln", "include \"a.kiln\"\nlet y = x + 1\n"}, {"a.kiln", "let x = 1\n"}});
  EXPECT_NO_THROW(Evaluator(vfs).evaluate());

  Vfs twice = kiln::testing::makeVfs(
      {{"main.kiln", "include \"a.kiln\"\ninclude \"a.kiln\"\n"}, {"a.kiln", "let x = 1\n"}});
  try {
    Evaluator(twice).evaluate();
    FAIL();
  } catch (const Error& e) {
    EXPECT_EQ(e.message(), "E_REDEFINE x");
  }

  Vfs cyc = kiln::testing::makeVfs({{"main.kiln", "include \"main.kiln\"\n"}});
  try {
    Evaluator(cyc).evaluate();
    FAIL();
  } catch (const Error& e) {
    EXPECT_EQ(e.message(), "E_INCLUDE_CYCLE main.kiln");
  }
  EXPECT_EQ(evalError("include \"nope.kiln\"\n"), "E_INCLUDE_MISSING nope.kiln");
  EXPECT_EQ(evalError("include \"../x\"\n"), "E_BAD_PATH ../x");
  EXPECT_EQ(evalError("include 1\n"), "E_TYPE include path: expected str, got int");
}

TEST(Interp, SyntaxErrorInIncludedFileNamesThatFile) {
  Vfs vfs = kiln::testing::makeVfs({{"main.kiln", "include \"a.kiln\"\n"}, {"a.kiln", "\nlet = 1\n"}});
  try {
    Evaluator(vfs).evaluate();
    FAIL();
  } catch (const Error& e) {
    EXPECT_EQ(e.message(), "E_PARSE a.kiln:2");
  }
}

TEST(Interp, RulesCaptureTheirDefiningScopeByReference) {
  Vfs vfs = kiln::testing::makeVfs({{"main.kiln",
      "let base = \"one\"\n"
      "rule r() {\n step {\n  out \"out/{base}\"\n  cmd write(\"x\")\n }\n}\n"
      "set base = \"two\"\n"
      "use r()\n"}});
  EXPECT_EQ(Evaluator(vfs).evaluate().steps[0].outputs[0], "out/two");
}

TEST(Interp, UseBinding) {
  const std::string rule = "rule r(a, b = a ~ \"x\") {\n step {\n  out \"out/{a}{b}\"\n  cmd write(\"x\")\n }\n}\n";
  EXPECT_EQ(evalError(rule + "use nope()\n"), "E_UNKNOWN_RULE nope");
  EXPECT_EQ(evalError(rule + "use r(1, 2, 3)\n"), "E_ARITY rule r: expected 2, got 3");
  EXPECT_EQ(evalError(rule + "use r(\"a\", c = 1)\n"), "E_ARG rule r: unknown argument c");
  EXPECT_EQ(evalError(rule + "use r(\"a\", a = \"b\")\n"), "E_ARG rule r: duplicate argument a");
  EXPECT_EQ(evalError(rule + "use r()\n"), "E_ARG rule r: missing argument a");
  EXPECT_EQ(evalError(rule + "use r(\"a\")\n"), "");
  EXPECT_EQ(evalError(rule + "rule r() {\n}\n"), "E_REDEFINE r");
}

TEST(Interp, RuleRecursionLimit) {
  const std::string src = "rule loop(n) {\n use loop(n + 1)\n}\nuse loop(0)\n";
  EXPECT_EQ(evalError(src), "E_RULE_RECURSION loop");
}

TEST(Interp, StepErrors) {
  auto step = [](const std::string& body) { return "step {\n" + body + "}\n"; };
  EXPECT_EQ(evalError(step(" out \"out/a\"\n")), "E_STEP_FIELD missing cmd");
  EXPECT_EQ(evalError(step(" cmd write(\"x\")\n")), "E_STEP_FIELD missing out");
  EXPECT_EQ(evalError(step(" out \"out/a\"\n cmd write(\"x\")\n cmd write(\"y\")\n")), "E_STEP_FIELD duplicate cmd");
  EXPECT_EQ(evalError(step(" cost 1\n cost undefined\n")), "E_STEP_FIELD duplicate cost");
  EXPECT_EQ(evalError(step(" cost -1\n")), "E_ARG field cost: negative");
  EXPECT_EQ(evalError(step(" out \"a\"\n cmd write(\"x\")\n")), "E_OUTPUT_PATH a");
  EXPECT_EQ(evalError(step(" out \"out/a b\"\n cmd write(\"x\")\n")), "E_BAD_PATH out/a b");
  EXPECT_EQ(evalError(step(" out 1\n")), "E_TYPE field out: expected strlist, got int");
  EXPECT_EQ(evalError(step(" out [\"out/a\", 2]\n")), "E_TYPE field out: expected strlist, got int");
  EXPECT_EQ(evalError(step(" out \"out/a\"\n cmd nope()\n")), "E_UNKNOWN_CMD nope");
  EXPECT_EQ(evalError(step(" out \"out/a\"\n cmd grep()\n")), "E_ARITY cmd grep: expected 1, got 0");
  EXPECT_EQ(evalError(step(" out \"out/a\"\n cmd indent(\"x\")\n")),
            "E_TYPE cmd indent argument 1: expected int, got str");
  EXPECT_EQ(evalError(step(" out \"out/a\"\n in \"@1\"\n cmd write(\"x\")\n")), "E_BAD_PATH @1");
}

TEST(Interp, CommandShapeErrors) {
  auto step = [](const std::string& body) { return "step {\n" + body + "}\n"; };
  EXPECT_EQ(evalError(step(" out \"out/a\"\n in \"x\"\n cmd write(\"x\")\n")),
            "E_CMD_SHAPE write: expected inputs 0-0, got 1");
  EXPECT_EQ(evalError(step(" out \"out/a\"\n cmd copy()\n")), "E_CMD_SHAPE copy: expected inputs 1-1, got 0");
  EXPECT_EQ(evalError(step(" out \"out/a\"\n cmd concat()\n")), "E_CMD_SHAPE concat: expected inputs 1-N, got 0");
  EXPECT_EQ(evalError(step(" out [\"out/a\", \"out/b\"]\n cmd write(\"x\")\n")),
            "E_CMD_SHAPE write: expected outputs 1, got 2");
  EXPECT_EQ(evalError(step(" out \"out/a\"\n in \"x\"\n cmd preprocess()\n")),
            "E_CMD_SHAPE preprocess: depfile required");
  EXPECT_EQ(evalError(step(" out \"out/a\"\n depfile \"out/a.d\"\n cmd write(\"x\")\n")),
            "E_CMD_SHAPE write: depfile not allowed");
  EXPECT_EQ(evalError(step(" out \"out/a\"\n in \"x\"\n cmd replace(\"\", \"y\")\n")),
            "E_ARG cmd replace: empty pattern");
  EXPECT_EQ(evalError(step(" out \"out/a\"\n in \"x\"\n cmd indent(-1)\n")), "E_ARG cmd indent: negative");
}

TEST(Interp, PhonyAndDefault) {
  EXPECT_EQ(evalError("phony a = []\nphony a = []\n"), "E_DUP_PHONY a");
  EXPECT_EQ(evalError("phony a = 1\n"), "E_TYPE phony a: expected strlist, got int");
  EXPECT_EQ(evalError("phony a = [\"bad path\"]\n"), "E_BAD_PATH bad path");
  EXPECT_EQ(evalError("default 1\n"), "E_TYPE default: expected strlist, got int");
  EXPECT_EQ(evalError("abort 1\n"), "E_TYPE abort message: expected str, got int");
}

TEST(Interp, NoBuildFile) {
  Vfs vfs;
  try {
    Evaluator(vfs).evaluate();
    FAIL();
  } catch (const Error& e) {
    EXPECT_EQ(e.message(), "E_NO_BUILD_FILE main.kiln");
  }
}
