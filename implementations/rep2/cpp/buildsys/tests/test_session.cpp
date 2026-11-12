#include <gtest/gtest.h>

#include "test_util.hpp"

using namespace kiln;
using kiln::testing::makeVfs;

namespace {
const char* kHello = "step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n";
}

TEST(Session, ParsesStepKinds) {
  auto steps = parseSession("# comment\n\nbuild @all -j 4\nbuild -j\nbuild a b\ncreate x\nl1\n  l2 \n---\ndelete y\ntouch z\nclean\n");
  ASSERT_EQ(steps.size(), 7u);
  EXPECT_EQ(steps[0].targets, (std::vector<std::string>{"@all"}));
  EXPECT_EQ(steps[0].jobs, 4);
  EXPECT_EQ(steps[1].targets, (std::vector<std::string>{"-j"}));  // `-j` as the only word is a target
  EXPECT_EQ(steps[1].jobs, 1);
  EXPECT_EQ(steps[2].targets.size(), 2u);
  EXPECT_EQ(steps[3].content, "l1\n  l2 \n");
  EXPECT_EQ(steps[6].kind, SessionStep::Clean);
}

TEST(Session, Example1And2) {
  Vfs vfs = makeVfs({{"main.kiln", kHello}});
  std::string log = runSession(vfs, "build\nbuild\ntouch main.kiln\nbuild\n");
  EXPECT_EQ(log,
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
  EXPECT_EQ(*vfs.read("out/hello.txt"), "hello\n");
  EXPECT_EQ(*vfs.read(".kiln-state"),
            "kiln-state 1\nstep out/hello.txt\ncmd write(\"hello\\n\")\nout out/hello.txt a9bc80cca21f28b3\nend\n");
}

TEST(Session, ParallelSchedulingAndTieBreaking) {
  std::string main;
  const char* names[] = {"a", "b", "c", "d"};
  const int costs[] = {3, 1, 4, 2};
  for (int i = 0; i < 4; ++i)
    main += std::string("step {\n out \"out/") + names[i] + ".txt\"\n cmd write(\"" + names[i] +
            "\\n\")\n cost " + std::to_string(costs[i]) + "\n}\n";
  main += "step {\n out \"out/all.txt\"\n in [\"out/a.txt\", \"out/b.txt\", \"out/c.txt\", \"out/d.txt\"]\n cmd concat()\n cost 2\n}\n"
          "default \"out/all.txt\"\n";
  Vfs vfs = makeVfs({{"main.kiln", main}});
  EXPECT_EQ(runSession(vfs, "build -j 2\n"),
            "step 1: build (default) -j 2\n"
            "  run 0 3 w0 out/a.txt write(\"a\\n\")\n"
            "  run 0 1 w1 out/b.txt write(\"b\\n\")\n"
            "  run 1 5 w1 out/c.txt write(\"c\\n\")\n"
            "  run 3 5 w0 out/d.txt write(\"d\\n\")\n"
            "  run 5 7 w0 out/all.txt concat()\n"
            "  ok ran=5 hit=0 time=7\n");
}

TEST(Session, EarlyCutoff) {
  Vfs vfs = makeVfs({{"src/a.txt", "abc\n"},
                     {"main.kiln",
                      "step {\n out \"out/mid.txt\"\n in \"src/a.txt\"\n cmd upper()\n}\n"
                      "step {\n out \"out/final.txt\"\n in \"out/mid.txt\"\n cmd number()\n}\n"
                      "default \"out/final.txt\"\n"}});
  EXPECT_EQ(runSession(vfs, "build\nedit src/a.txt\nABC\n---\nbuild\n"),
            "step 1: build (default) -j 1\n"
            "  run 0 2 w0 out/mid.txt upper()\n"
            "  run 2 4 w0 out/final.txt number()\n"
            "  ok ran=2 hit=0 time=4\n"
            "step 2: edit src/a.txt\n"
            "  ok size=4\n"
            "step 3: build (default) -j 1\n"
            "  run 0 2 w0 out/mid.txt upper()\n"
            "  hit 2 out/final.txt\n"
            "  ok ran=1 hit=1 time=2\n");
}

TEST(Session, FailureCancelsRunningWork) {
  Vfs vfs = makeVfs({{"src/main.txt", "@need src/gone.txt\n"},
                     {"main.kiln",
                      "step {\n out \"out/doc.txt\"\n depfile \"out/doc.d\"\n in \"src/main.txt\"\n cmd preprocess()\n}\n"
                      "step {\n out \"out/slow.txt\"\n cmd write(\"slow\\n\")\n cost 10\n}\n"
                      "step {\n out \"out/after.txt\"\n in \"out/doc.txt\"\n cmd copy()\n}\n"
                      "phony all = [\"out/doc.txt\", \"out/slow.txt\", \"out/after.txt\"]\ndefault \"@all\"\n"}});
  EXPECT_EQ(runSession(vfs, "build -j 2\n"),
            "step 1: build (default) -j 2\n"
            "  fail 0 6 w0 out/doc.txt preprocess()\n"
            "  cancel 0 10 w1 out/slow.txt write(\"slow\\n\")\n"
            "  error E_NEED_MISSING src/gone.txt needed by src/main.txt\n");
  EXPECT_EQ(*vfs.read(".kiln-state"), "kiln-state 1\n");
  EXPECT_FALSE(vfs.exists("out/slow.txt"));
}

TEST(Session, AfterIsOrderOnly) {
  Vfs vfs = makeVfs({{"src/a.txt", "a\n"},
                     {"main.kiln",
                      "step {\n out \"out/gen.txt\"\n in \"src/a.txt\"\n cmd copy()\n}\n"
                      "step {\n out \"out/rep.txt\"\n after \"out/gen.txt\"\n cmd write(\"report\\n\")\n}\n"
                      "phony all = [\"out/rep.txt\"]\ndefault \"@all\"\n"}});
  EXPECT_EQ(runSession(vfs, "build\nedit src/a.txt\nb\n---\nbuild\n"),
            "step 1: build (default) -j 1\n"
            "  run 0 1 w0 out/gen.txt copy()\n"
            "  run 1 2 w0 out/rep.txt write(\"report\\n\")\n"
            "  ok ran=2 hit=0 time=2\n"
            "step 2: edit src/a.txt\n"
            "  ok size=2\n"
            "step 3: build (default) -j 1\n"
            "  run 0 1 w0 out/gen.txt copy()\n"
            "  hit 1 out/rep.txt\n"
            "  ok ran=1 hit=1 time=1\n");
}

TEST(Session, DiscoveredDependenciesTriggerRebuild) {
  Vfs vfs = makeVfs({{"src/main.txt", "title\n@need src/part.txt\nend\n"},
                     {"src/part.txt", "PART\n"},
                     {"main.kiln",
                      "step {\n out \"out/doc.txt\"\n depfile \"out/doc.d\"\n in \"src/main.txt\"\n cmd preprocess()\n}\n"
                      "default \"out/doc.txt\"\n"}});
  std::string log = runSession(vfs, "build\nbuild\nedit src/part.txt\nP2\n---\nbuild\n");
  EXPECT_NE(log.find("step 2: build (default) -j 1\n  hit 0 out/doc.txt"), std::string::npos);
  EXPECT_NE(log.find("step 4: build (default) -j 1\n  run 0 6 w0 out/doc.txt preprocess()"), std::string::npos);
  EXPECT_EQ(*vfs.read("out/doc.txt"), "title\nP2\nend\n");
  EXPECT_EQ(*vfs.read("out/doc.d"), "kiln-deps 1\nneed src/part.txt\n");
}

TEST(Session, CleanRemovesGeneratedFiles) {
  Vfs vfs = makeVfs({{"main.kiln", kHello}});
  EXPECT_EQ(runSession(vfs, "build\nclean\nbuild\n"),
            "step 1: build (default) -j 1\n"
            "  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n"
            "  ok ran=1 hit=0 time=1\n"
            "step 2: clean\n"
            "  remove .kiln-state\n"
            "  remove out/hello.txt\n"
            "  ok removed=2\n"
            "step 3: build (default) -j 1\n"
            "  run 0 1 w0 out/hello.txt write(\"hello\\n\")\n"
            "  ok ran=1 hit=0 time=1\n");
}

TEST(Session, TamperedAndDeletedOutputsRebuild) {
  Vfs vfs = makeVfs({{"main.kiln", kHello}});
  std::string log = runSession(vfs, "build\nedit out/hello.txt\ntampered\n---\nbuild\ndelete out/hello.txt\nbuild\n");
  EXPECT_NE(log.find("step 3: build (default) -j 1\n  run 0 1"), std::string::npos);
  EXPECT_NE(log.find("step 5: build (default) -j 1\n  run 0 1"), std::string::npos);
  EXPECT_NE(log.find("step 2: edit out/hello.txt\n  ok size=9"), std::string::npos);
}

TEST(Session, CostAndDependencySetAreDistinguished) {
  auto mk = [](const char* ins, const char* cost) {
    return std::string("step {\n out \"out/j.txt\"\n in ") + ins + "\n cmd concat()\n" + cost + "}\ndefault \"out/j.txt\"\n";
  };
  Vfs vfs = makeVfs({{"src/a.txt", "a\n"}, {"src/b.txt", "a\n"},
                     {"main.kiln", mk("[\"src/a.txt\", \"src/b.txt\"]", "")}});
  runSession(vfs, "build\n");
  vfs.write("main.kiln", mk("[\"src/a.txt\", \"src/b.txt\"]", " cost 5\n"));
  EXPECT_NE(runSession(vfs, "build\n").find("hit 0 out/j.txt"), std::string::npos);
  vfs.write("main.kiln", mk("[\"src/b.txt\", \"src/a.txt\"]", " cost 5\n"));
  EXPECT_NE(runSession(vfs, "build\n").find("run 0 5 w0 out/j.txt concat()"), std::string::npos);
}

TEST(Session, CorruptStateRebuildsEverything) {
  Vfs vfs = makeVfs({{"main.kiln", kHello}, {".kiln-state", "garbage\n"}});
  std::string log = runSession(vfs, "build\n");
  EXPECT_NE(log.find("run 0 1"), std::string::npos);
  EXPECT_EQ(vfs.read(".kiln-state")->substr(0, 13), "kiln-state 1\n");
}

TEST(Session, StateFileWrittenEvenWhenNothingRan) {
  Vfs vfs = makeVfs({{"main.kiln", kHello}});
  runSession(vfs, "build\n");
  vfs.write(".kiln-state", "kiln-state 1\nstep gone/x\ncmd c\nout gone/x 0000000000000000\nend\n");
  runSession(vfs, "build\n");
  // Entries for steps that no longer exist are carried over.
  EXPECT_NE(vfs.read(".kiln-state")->find("step gone/x"), std::string::npos);
}

TEST(Session, EmptySessionHasEmptyLog) {
  Vfs vfs;
  EXPECT_EQ(runSession(vfs, "\n# nothing\n"), "");
}
