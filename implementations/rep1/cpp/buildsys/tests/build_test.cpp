// End-to-end tests of builds and sessions, including the specification's worked examples.
#include <gtest/gtest.h>

#include <filesystem>
#include <fstream>

#include "support.hpp"

using namespace kiln;
using testing_support::build_error;
using testing_support::run;
using testing_support::workspace;

namespace {

const char* kHello =
    "step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n";

std::string content(const Vfs& v, const char* path) {
  auto c = v.read(path);
  return c ? *c : std::string("<missing>");
}

}  // namespace

TEST(Session, Example1OneStep) {
  Vfs ws = workspace({{"main.kiln", kHello}});
  EXPECT_EQ(run(ws, "build\n"),
            "step 1: build (default) -j 1\n"
            "  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n"
            "  ok ran=1 hit=0 time=1\n");
  EXPECT_EQ(content(ws, "out/hello.txt"), "hello\n");
  EXPECT_EQ(content(ws, ".kiln-state"),
            "kiln-state 1\nstep out/hello.txt\ncmd write(\"hello\\n\")\nout out/hello.txt a9bc80cca21f28b3\nend\n");
}

TEST(Session, Example2TouchIsNotAChange) {
  Vfs ws = workspace({{"main.kiln", kHello}});
  EXPECT_EQ(run(ws, "build\nbuild\ntouch main.kiln\nbuild\n"),
            "step 1: build (default) -j 1\n"
            "  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n"
            "  ok ran=1 hit=0 time=1\n"
            "step 2: build (default) -j 1\n"
            "  hit 0 out/hello.txt\n"
            "  ok ran=0 hit=1 time=0\n"
            "step 3: touch main.kiln\n"
            "  ok\n"
            "step 4: build (default) -j 1\n"
            "  hit 0 out/hello.txt\n"
            "  ok ran=0 hit=1 time=0\n");
}

TEST(Session, Example3ParallelSchedulingAndTieBreaks) {
  Vfs ws = workspace({{"main.kiln",
                       "step {\n out \"out/a.txt\"\n cmd write(\"A\\n\")\n cost 3\n}\n"
                       "step {\n out \"out/b.txt\"\n cmd write(\"B\\n\")\n cost 1\n}\n"
                       "step {\n out \"out/c.txt\"\n cmd write(\"C\\n\")\n cost 4\n}\n"
                       "step {\n out \"out/d.txt\"\n cmd write(\"D\\n\")\n cost 2\n}\n"
                       "step {\n out \"out/all.txt\"\n in [\"out/a.txt\", \"out/b.txt\", \"out/c.txt\", \"out/d.txt\"]\n"
                       " cmd concat()\n cost 2\n}\n"
                       "default \"out/all.txt\"\n"}});
  EXPECT_EQ(run(ws, "build -j 2\n"),
            "step 1: build (default) -j 2\n"
            "  run 0 3 w0 out/a.txt write(\"A\\n\")\n"
            "  run 0 1 w1 out/b.txt write(\"B\\n\")\n"
            "  run 1 5 w1 out/c.txt write(\"C\\n\")\n"
            "  run 3 5 w0 out/d.txt write(\"D\\n\")\n"
            "  run 5 7 w0 out/all.txt concat()\n"
            "  ok ran=5 hit=0 time=7\n");
  EXPECT_EQ(content(ws, "out/all.txt"), "A\nB\nC\nD\n");
}

TEST(Session, Example4VariablesEachMapPhony) {
  Vfs ws = workspace({{"main.kiln",
                       "let names = [\"alpha\", \"beta\", \"gamma\"]\n"
                       "let outs = map(names, \"out/%.txt\")\n"
                       "each i, n in names {\n step {\n out \"out/{n}.txt\"\n cmd write(\"{i}:{n}\\n\")\n cost 1\n }\n}\n"
                       "step {\n out \"out/index.txt\"\n in outs\n cmd concat()\n}\n"
                       "phony all = [\"out/index.txt\"]\ndefault \"@all\"\n"}});
  EXPECT_EQ(run(ws, "build @all -j 3\n"),
            "step 1: build @all -j 3\n"
            "  run 0 1 w0 out/alpha.txt write(\"0:alpha\\n\")\n"
            "  run 0 1 w1 out/beta.txt write(\"1:beta\\n\")\n"
            "  run 0 1 w2 out/gamma.txt write(\"2:gamma\\n\")\n"
            "  run 1 3 w0 out/index.txt concat()\n"
            "  ok ran=4 hit=0 time=3\n");
  EXPECT_EQ(content(ws, "out/index.txt"), "0:alpha\n1:beta\n2:gamma\n");
}

TEST(Session, Example5RulesAndChains) {
  Vfs ws = workspace({{"src/a.txt", "AAA\n"},
                      {"src/b.txt", "BBB\n"},
                      {"main.kiln",
                       "rule bundle(name, parts, weight = 2) {\n step {\n out \"out/{name}.txt\"\n in parts\n"
                       " cmd concat()\n cost weight\n }\n}\n"
                       "let base = [\"src/a.txt\", \"src/b.txt\"]\n"
                       "use bundle(\"one\", base)\n"
                       "use bundle(name = \"two\", parts = base ++ [\"out/one.txt\"], weight = 5)\n"
                       "phony all = [\"out/one.txt\", \"out/two.txt\"]\ndefault \"@all\"\n"}});
  EXPECT_EQ(run(ws, "build -j 2\n"),
            "step 1: build (default) -j 2\n"
            "  run 0 2 w0 out/one.txt concat()\n"
            "  run 2 7 w0 out/two.txt concat()\n"
            "  ok ran=2 hit=0 time=7\n");
  EXPECT_EQ(content(ws, ".kiln-state"),
            "kiln-state 1\n"
            "step out/one.txt\ncmd concat()\nin src/a.txt 8943a78b9f342c58\nin src/b.txt c857dca71c36fafd\n"
            "out out/one.txt 5e52e06e8b405ae8\nend\n"
            "step out/two.txt\ncmd concat()\nin src/a.txt 8943a78b9f342c58\nin src/b.txt c857dca71c36fafd\n"
            "in out/one.txt 5e52e06e8b405ae8\nout out/two.txt f98ee131e7582add\nend\n");
}

TEST(Session, Example6GlobIncludeSetWhen) {
  Vfs ws = workspace({{"src/a.txt", "a1\n"}, {"src/b.txt", "b1\n"}, {"src/sub/c.txt", "c1\n"}, {"src/notes.md", "note\n"},
                      {"tune.kiln", "set mode = \"slow\"\nlet extra = 1\n"},
                      {"main.kiln",
                       "let mode = \"fast\"\nlet flags = []\ninclude \"tune.kiln\"\n"
                       "when mode == \"fast\" {\n set flags = flags ++ [\"F\"]\n} otherwise {\n set flags = flags ++ [\"S\"]\n}\n"
                       "let srcs = glob(\"src/**/*.txt\")\n"
                       "step {\n out \"out/list.txt\"\n in srcs\n cmd count_lines()\n}\n"
                       "step {\n out \"out/flags.txt\"\n cmd write(\"{join(flags, \",\")}\\n\")\n}\n"
                       "default [\"out/list.txt\", \"out/flags.txt\"]\n"}});
  EXPECT_EQ(run(ws, "build -j 2\n"),
            "step 1: build (default) -j 2\n"
            "  run 0 2 w0 out/list.txt count_lines()\n"
            "  run 0 1 w1 out/flags.txt write(\"S\\n\")\n"
            "  ok ran=2 hit=0 time=2\n");
  EXPECT_EQ(content(ws, "out/list.txt"), "1 src/a.txt\n1 src/b.txt\n1 src/sub/c.txt\n3 total\n");
}

TEST(Session, Example7PreprocessAndDiscoveredDependencies) {
  Vfs ws = workspace({{"src/main.txt", "title\n@need src/part.txt\nend\n"},
                      {"src/part.txt", "PART-A\n@need src/deep.txt\n"},
                      {"src/deep.txt", "DEEP\n"},
                      {"main.kiln",
                       "step {\n out \"out/doc.txt\"\n depfile \"out/doc.d\"\n in \"src/main.txt\"\n cmd preprocess()\n}\n"
                       "default \"out/doc.txt\"\n"}});
  EXPECT_EQ(run(ws, "build\nbuild\nedit src/deep.txt\nDEEP2\n---\nbuild\n"),
            "step 1: build (default) -j 1\n  run 0 6 w0 out/doc.txt preprocess()\n  ok ran=1 hit=0 time=6\n"
            "step 2: build (default) -j 1\n  hit 0 out/doc.txt\n  ok ran=0 hit=1 time=0\n"
            "step 3: edit src/deep.txt\n  ok size=6\n"
            "step 4: build (default) -j 1\n  run 0 6 w0 out/doc.txt preprocess()\n  ok ran=1 hit=0 time=6\n");
  EXPECT_EQ(content(ws, "out/doc.txt"), "title\nPART-A\nDEEP2\nend\n");
  EXPECT_EQ(content(ws, "out/doc.d"), "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n");
  EXPECT_EQ(content(ws, ".kiln-state"),
            "kiln-state 1\nstep out/doc.txt\ncmd preprocess()\nin src/main.txt 993a20756b253540\n"
            "dep src/deep.txt 06ae7bdd484568d7\ndep src/part.txt a8442a790131f243\n"
            "out out/doc.txt f755eb555e1be12f\nout out/doc.d ea603661a409bc02\nend\n");
}

TEST(Session, Example8EarlyCutoff) {
  Vfs ws = workspace({{"src/a.txt", "abc\n"},
                      {"main.kiln",
                       "step {\n out \"out/mid.txt\"\n in \"src/a.txt\"\n cmd upper()\n}\n"
                       "step {\n out \"out/final.txt\"\n in \"out/mid.txt\"\n cmd number()\n}\n"
                       "default \"out/final.txt\"\n"}});
  EXPECT_EQ(run(ws, "build\nedit src/a.txt\nABC\n---\nbuild\n"),
            "step 1: build (default) -j 1\n  run 0 2 w0 out/mid.txt upper()\n  run 2 4 w0 out/final.txt number()\n"
            "  ok ran=2 hit=0 time=4\n"
            "step 2: edit src/a.txt\n  ok size=4\n"
            "step 3: build (default) -j 1\n  run 0 2 w0 out/mid.txt upper()\n  hit 2 out/final.txt\n"
            "  ok ran=1 hit=1 time=2\n");
}

TEST(Session, Example9CycleLeavesWorkspaceUntouched) {
  Vfs ws = workspace({{"main.kiln",
                       "step {\n out \"out/x.txt\"\n in \"out/y.txt\"\n cmd copy()\n}\n"
                       "step {\n out \"out/y.txt\"\n in \"out/x.txt\"\n cmd copy()\n}\n"
                       "default \"out/x.txt\"\n"}});
  EXPECT_EQ(run(ws, "build\n"),
            "step 1: build (default) -j 1\n  error E_CYCLE out/x.txt -> out/y.txt -> out/x.txt\n");
  EXPECT_EQ(ws.size(), 1u);
}

TEST(Session, Example10ConfigurationErrors) {
  EXPECT_EQ(build_error("step {\n out \"out/z.txt\"\n cmd write(\"1\\n\")\n}\nstep {\n out \"out/z.txt\"\n cmd write(\"2\\n\")\n}\n"
                        "default \"out/z.txt\"\n"),
            "E_DUP_OUTPUT out/z.txt");
  EXPECT_EQ(build_error("step {\n out \"out/z.txt\"\n in [\"src/a.txt\", \"src/missing.txt\"]\n cmd concat()\n}\ndefault \"out/z.txt\"\n",
                        {{"src/a.txt", "a\n"}}),
            "E_MISSING_INPUT src/missing.txt required by out/z.txt");
  EXPECT_EQ(build_error("step {\n out \"out/z.txt\"\n cmd write(greeting)\n}\ndefault \"out/z.txt\"\n"), "E_UNKNOWN_VAR greeting");
  EXPECT_EQ(build_error("let n = 3\nwhen n > 2 {\n abort \"n too large: {n}\"\n}\n"), "E_ABORT n too large: 3");
  EXPECT_EQ(build_error("step {\n out \"out/z.txt\"\n cmd write(\"ok\\n\")\n}\n"), "E_NO_DEFAULT");
}

TEST(Session, Example11Clean) {
  Vfs ws = workspace({{"main.kiln", kHello}});
  EXPECT_EQ(run(ws, "build\nclean\nbuild\n"),
            "step 1: build (default) -j 1\n  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n"
            "step 2: clean\n  remove .kiln-state\n  remove out/hello.txt\n  ok removed=2\n"
            "step 3: build (default) -j 1\n  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n  ok ran=1 hit=0 time=1\n");
}

TEST(Session, Example12ExecutionErrorCancelsWorkInFlight) {
  Vfs ws = workspace({{"src/main.txt", "@need src/gone.txt\n"},
                      {"main.kiln",
                       "step {\n out \"out/doc.txt\"\n depfile \"out/doc.d\"\n in \"src/main.txt\"\n cmd preprocess()\n}\n"
                       "step {\n out \"out/slow.txt\"\n cmd write(\"slow\\n\")\n cost 10\n}\n"
                       "step {\n out \"out/after.txt\"\n in \"out/doc.txt\"\n cmd copy()\n}\n"
                       "phony all = [\"out/doc.txt\", \"out/slow.txt\", \"out/after.txt\"]\ndefault \"@all\"\n"}});
  EXPECT_EQ(run(ws, "build -j 2\n"),
            "step 1: build (default) -j 2\n"
            "  fail 0 6 w0 out/doc.txt preprocess()\n"
            "  cancel 0 10 w1 out/slow.txt write(\"slow\\n\")\n"
            "  error E_NEED_MISSING src/gone.txt needed by src/main.txt\n");
  EXPECT_EQ(content(ws, ".kiln-state"), "kiln-state 1\n");
  EXPECT_FALSE(ws.exists("out/slow.txt"));
}

TEST(Session, Example13AfterIsOrderOnly) {
  Vfs ws = workspace({{"src/a.txt", "a\n"},
                      {"main.kiln",
                       "step {\n out \"out/gen.txt\"\n in \"src/a.txt\"\n cmd copy()\n}\n"
                       "step {\n out \"out/rep.txt\"\n after \"out/gen.txt\"\n cmd write(\"report\\n\")\n}\n"
                       "phony all = [\"out/rep.txt\"]\ndefault \"@all\"\n"}});
  EXPECT_EQ(run(ws, "build\nedit src/a.txt\nb\n---\nbuild\n"),
            "step 1: build (default) -j 1\n  run 0 1 w0 out/gen.txt copy()\n  run 1 2 w0 out/rep.txt write(\"report\\n\")\n"
            "  ok ran=2 hit=0 time=2\n"
            "step 2: edit src/a.txt\n  ok size=2\n"
            "step 3: build (default) -j 1\n  run 0 1 w0 out/gen.txt copy()\n  hit 1 out/rep.txt\n  ok ran=1 hit=1 time=1\n");
}

TEST(Session, Example14CostIsNotAChangeButTheDependencySetIs) {
  const std::string head = "step {\n out \"out/j.txt\"\n in ";
  Vfs ws = workspace({{"src/a.txt", "a\n"}, {"src/b.txt", "a\n"},
                      {"main.kiln", (head + "[\"src/a.txt\", \"src/b.txt\"]\n cmd concat()\n}\ndefault \"out/j.txt\"\n").c_str()}});
  std::string script =
      "build\nedit main.kiln\n" + head + "[\"src/a.txt\", \"src/b.txt\"]\n cmd concat()\n cost 5\n}\ndefault \"out/j.txt\"\n---\n"
      "build\nedit main.kiln\n" + head + "[\"src/b.txt\", \"src/a.txt\"]\n cmd concat()\n cost 5\n}\ndefault \"out/j.txt\"\n---\nbuild\n";
  std::string log = run(ws, script);
  EXPECT_NE(log.find("step 3: build (default) -j 1\n  hit 0 out/j.txt\n  ok ran=0 hit=1 time=0\n"), std::string::npos) << log;
  EXPECT_NE(log.find("step 5: build (default) -j 1\n  run 0 5 w0 out/j.txt concat()\n  ok ran=1 hit=0 time=5\n"), std::string::npos) << log;
}

TEST(Session, Example15TamperedAndDeletedOutputsAreRebuilt) {
  Vfs ws = workspace({{"main.kiln", kHello}});
  std::string log = run(ws, "build\nedit out/hello.txt\ntampered\n---\nbuild\ndelete out/hello.txt\nbuild\n");
  EXPECT_NE(log.find("step 2: edit out/hello.txt\n  ok size=9\n"), std::string::npos);
  EXPECT_NE(log.find("step 3: build (default) -j 1\n  run 0 1 w0"), std::string::npos);
  EXPECT_NE(log.find("step 5: build (default) -j 1\n  run 0 1 w0"), std::string::npos);
  EXPECT_EQ(content(ws, "out/hello.txt"), "hello\n");
}

// --- behaviour beyond the worked examples ---------------------------------

TEST(Build, MissingBuildFile) {
  Vfs ws;
  EXPECT_EQ(run(ws, "build\n"), "step 1: build (default) -j 1\n  error E_NO_BUILD_FILE main.kiln\n");
}

TEST(Build, ConfigurationErrorsDoNotWriteState) {
  Vfs ws = workspace({{"main.kiln", "abort \"no\"\n"}});
  run(ws, "build\n");
  EXPECT_FALSE(ws.exists(".kiln-state"));
}

TEST(Build, ExplicitTargetsAndUnknownTargets) {
  Vfs ws = workspace({{"main.kiln", kHello}, {"src/s.txt", "s\n"}});
  EXPECT_EQ(run(ws, "build nope\nbuild @nope -j 4\nbuild src/s.txt\nbuild out/hello.txt out/hello.txt\n"),
            "step 1: build nope -j 1\n  error E_UNKNOWN_TARGET nope\n"
            "step 2: build @nope -j 4\n  error E_UNKNOWN_TARGET @nope\n"
            "step 3: build src/s.txt -j 1\n  ok ran=0 hit=0 time=0\n"
            "step 4: build out/hello.txt out/hello.txt -j 1\n  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n"
            "  ok ran=1 hit=0 time=1\n");
}

TEST(Build, DefaultListIsValidatedEvenWhenTargetsAreGiven) {
  Vfs ws = workspace({{"main.kiln",
                       "step {\n out \"out/a\"\n cmd write(\"a\")\n}\ndefault [\"out/a\", \"out/ghost\"]\n"}});
  EXPECT_EQ(run(ws, "build out/a\n"), "step 1: build out/a -j 1\n  error E_UNKNOWN_TARGET out/ghost\n");
}

TEST(Build, SelfDependencyIsATwoNodeCycle) {
  EXPECT_EQ(build_error("step {\n out \"out/a.txt\"\n in \"out/a.txt\"\n cmd copy()\n}\ndefault \"out/a.txt\"\n"),
            "E_CYCLE out/a.txt -> out/a.txt");
}

TEST(Build, CyclesOutsideTheReachableSetAreIgnored) {
  Vfs ws = workspace({{"main.kiln",
                       "step {\n out \"out/ok\"\n cmd write(\"1\")\n}\n"
                       "step {\n out \"out/x\"\n in \"out/y\"\n cmd copy()\n}\n"
                       "step {\n out \"out/y\"\n in \"out/x\"\n cmd copy()\n}\n"
                       "default \"out/ok\"\n"}});
  EXPECT_EQ(run(ws, "build\nbuild out/x\n"),
            "step 1: build (default) -j 1\n  run 0 1 w0 out/ok write(\"1\")\n  ok ran=1 hit=0 time=1\n"
            "step 2: build out/x -j 1\n  error E_CYCLE out/x -> out/y -> out/x\n");
}

TEST(Build, MissingInputIsReportedForUnreachableStepsToo) {
  EXPECT_EQ(build_error("step {\n out \"out/ok\"\n cmd write(\"1\")\n}\nstep {\n out \"out/b\"\n in \"@ghost\"\n cmd write(\"2\")\n}\n"
                        "default \"out/ok\"\n"),
            "E_MISSING_INPUT @ghost required by out/b");
}

TEST(Build, DepfileCountsForDuplicateDetection) {
  EXPECT_EQ(build_error("step {\n out \"out/a\"\n depfile \"out/d\"\n in \"main.kiln\"\n cmd preprocess()\n}\n"
                        "step {\n out \"out/d\"\n cmd write(\"\")\n}\ndefault \"out/a\"\n"),
            "E_DUP_OUTPUT out/d");
}

TEST(Build, ZeroCostStepsStillRunAndLog) {
  Vfs ws = workspace({{"main.kiln",
                       "step {\n out \"out/a\"\n cmd write(\"a\")\n cost 0\n}\n"
                       "step {\n out \"out/b\"\n in \"out/a\"\n cmd copy()\n cost 0\n}\ndefault \"out/b\"\n"}});
  EXPECT_EQ(run(ws, "build\n"),
            "step 1: build (default) -j 1\n  run 0 0 w0 out/a write(\"a\")\n  run 0 0 w0 out/b copy()\n  ok ran=2 hit=0 time=0\n");
}

TEST(Build, CorruptStateMeansEverythingRebuilds) {
  Vfs ws = workspace({{"main.kiln", kHello}, {".kiln-state", "garbage\n"}});
  std::string log = run(ws, "build\n");
  EXPECT_NE(log.find("run 0 1 w0"), std::string::npos);
  EXPECT_EQ(content(ws, ".kiln-state").substr(0, 13), "kiln-state 1\n");
}

TEST(Build, StateIsRewrittenAndKeepsEntriesOfOtherSteps) {
  Vfs ws = workspace({{"main.kiln", kHello}});
  run(ws, "build\n");
  std::string before = content(ws, ".kiln-state");
  ws.write("main.kiln", "step {\n out \"out/other\"\n cmd write(\"o\")\n}\ndefault \"out/other\"\n");
  run(ws, "build\n");
  std::string after = content(ws, ".kiln-state");
  EXPECT_NE(after.find("step out/hello.txt"), std::string::npos);
  EXPECT_NE(after.find("step out/other"), std::string::npos);
  (void)before;
}

TEST(Build, ChangingTheCommandMakesAStepStale) {
  Vfs ws = workspace({{"src/a", "a\n"},
                      {"main.kiln", "step {\n out \"out/o\"\n in \"src/a\"\n cmd indent(1)\n}\ndefault \"out/o\"\n"}});
  run(ws, "build\n");
  ws.write("main.kiln", "step {\n out \"out/o\"\n in \"src/a\"\n cmd indent(2)\n}\ndefault \"out/o\"\n");
  std::string log = run(ws, "build\n");
  EXPECT_NE(log.find("run 0 2 w0 out/o indent(2)"), std::string::npos) << log;
}

TEST(Build, PhonyReferencesInInputsOrderButDoNotAffectFreshness) {
  Vfs ws = workspace({{"main.kiln",
                       "step {\n out \"out/pre\"\n cmd write(\"p\")\n cost 3\n}\nphony pre = [\"out/pre\"]\n"
                       "step {\n out \"out/main\"\n in [\"@pre\", \"main.kiln\"]\n cmd copy()\n}\ndefault \"out/main\"\n"}});
  EXPECT_EQ(run(ws, "build\n"),
            "step 1: build (default) -j 1\n  run 0 3 w0 out/pre write(\"p\")\n  run 3 4 w0 out/main copy()\n"
            "  ok ran=2 hit=0 time=4\n");
}

TEST(Build, SimultaneousFailuresReportTheLowestSerial) {
  Vfs ws = workspace({{"src/m1", "@need gone1\n"}, {"src/m2", "@need gone2\n"},
                      {"main.kiln",
                       "step {\n out \"out/a\"\n depfile \"out/a.d\"\n in \"src/m2\"\n cmd preprocess()\n}\n"
                       "step {\n out \"out/b\"\n depfile \"out/b.d\"\n in \"src/m1\"\n cmd preprocess()\n}\n"
                       "default [\"out/a\", \"out/b\"]\n"}});
  EXPECT_EQ(run(ws, "build -j 2\n"),
            "step 1: build (default) -j 2\n  fail 0 6 w0 out/a preprocess()\n  fail 0 6 w1 out/b preprocess()\n"
            "  error E_NEED_MISSING gone2 needed by src/m2\n");
}

TEST(SessionParsing, StepsAndContentBlocks) {
  auto steps = parse_session(
      "# comment\n\n  \t\nbuild a b -j 4\nbuild\nbuild -j 3\ncreate x/y.txt\n  keep \t\n\n# not a comment\n---\n"
      "edit z\n---\ndelete d\ntouch t\nclean\n");
  ASSERT_EQ(steps.size(), 8u);
  EXPECT_EQ(steps[0].targets, (std::vector<std::string>{"a", "b"}));
  EXPECT_EQ(steps[0].workers, 4);
  EXPECT_TRUE(steps[1].targets.empty());
  EXPECT_EQ(steps[1].workers, 1);
  EXPECT_TRUE(steps[2].targets.empty());   // `-j 3` with nothing else
  EXPECT_EQ(steps[2].workers, 3);
  EXPECT_EQ(steps[3].content, "  keep \t\n\n# not a comment\n");
  EXPECT_EQ(steps[4].content, "");
  EXPECT_EQ(steps[5].kind, SessionStep::Kind::Delete);
  EXPECT_EQ(steps[7].kind, SessionStep::Kind::Clean);
}

TEST(SessionParsing, UnterminatedContentBlockIsRejected) {
  EXPECT_THROW(parse_session("create x\nabc\n"), std::runtime_error);
  EXPECT_THROW(parse_session("frobnicate\n"), std::runtime_error);
}

TEST(Workspace, LoadAndSaveRoundTrip) {
  namespace fs = std::filesystem;
  fs::path base = fs::temp_directory_path() / "kiln_vfs_test";
  fs::remove_all(base);
  fs::create_directories(base / "in/src");
  { std::ofstream(base / "in/session.txt") << "build\n"; }
  { std::ofstream(base / "in/src/a.txt", std::ios::binary) << std::string("a\0b", 3); }
  Vfs v = Vfs::load_directory((base / "in").string(), "session.txt");
  EXPECT_EQ(v.size(), 1u);
  EXPECT_EQ(content(v, "src/a.txt"), std::string("a\0b", 3));
  v.save_directory((base / "out/workspace").string());
  EXPECT_TRUE(fs::exists(base / "out/workspace/src/a.txt"));
  fs::remove_all(base);
}
