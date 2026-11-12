#include <gtest/gtest.h>

#include "support.hpp"

using namespace kiln;

namespace {
const char* kGood =
    "kiln-state 1\n"
    "step out/a.txt\n"
    "cmd write(\"a\")\n"
    "out out/a.txt 0123456789abcdef\n"
    "end\n"
    "step out/b.txt\n"
    "cmd concat()\n"
    "in src/x.txt 0123456789abcdef\n"
    "in src/x.txt 0123456789abcdef\n"
    "dep src/z 0123456789abcdef\n"
    "dep src/y 0123456789abcdef\n"
    "out out/b.txt 0123456789abcdef\n"
    "out out/b.d 0123456789abcdef\n"
    "end\n";
}

TEST(State, ParsesWellFormedFiles) {
  BuildState s = BuildState::parse(kGood);
  EXPECT_EQ(s.size(), 2u);
  const StateEntry* e = s.find("out/b.txt");
  ASSERT_NE(e, nullptr);
  EXPECT_EQ(e->inputs.size(), 2u);   // duplicates kept
  EXPECT_EQ(e->deps.front().first, "src/z");  // reading does not sort
  EXPECT_EQ(e->outputs.size(), 2u);
}

TEST(State, SerializesCanonically) {
  BuildState s;
  StateEntry e;
  e.command = "concat()";
  e.inputs = {{"src/a", 1}};
  e.deps = {{"src/d", 2}};
  e.outputs = {{"out/z", 3}};
  s.put("out/z", e);
  e.outputs = {{"out/a", 4}};
  s.put("out/a", e);
  EXPECT_EQ(s.serialize(),
            "kiln-state 1\n"
            "step out/a\ncmd concat()\nin src/a 0000000000000001\ndep src/d 0000000000000002\nout out/a 0000000000000004\nend\n"
            "step out/z\ncmd concat()\nin src/a 0000000000000001\ndep src/d 0000000000000002\nout out/z 0000000000000003\nend\n");
  EXPECT_EQ(BuildState::parse(s.serialize()).serialize(), s.serialize());
}

TEST(State, AnyDeviationYieldsEmptyState) {
  auto bad = [](std::string text) { return BuildState::parse(text).size() == 0; };
  std::string good = kGood;
  EXPECT_FALSE(bad(good));
  EXPECT_TRUE(bad(""));
  EXPECT_TRUE(bad("kiln-state 2\n"));
  EXPECT_TRUE(bad(good.substr(0, good.size() - 1)));                 // unterminated last line
  EXPECT_TRUE(bad(good.substr(0, good.size() - 4)));                 // missing `end`
  EXPECT_TRUE(bad(good + "stray\n"));
  EXPECT_TRUE(bad(good + "step out/c\ncmd x()\nend\n"));            // no out line
  EXPECT_TRUE(bad("kiln-state 1\nstep out/a\nout out/a 0123456789abcdef\nend\n"));  // no cmd
  EXPECT_TRUE(bad("kiln-state 1\nstep out/a\ncmd \nout out/a 0123456789abcdef\nend\n"));
  EXPECT_TRUE(bad("kiln-state 1\nstep out/a\ncmd x()\ncmd y()\nout out/a 0123456789abcdef\nend\n"));
  EXPECT_TRUE(bad("kiln-state 1\nstep out/a\ncmd x()\nout out/a 0123456789ABCDEF\nend\n"));  // uppercase hex
  EXPECT_TRUE(bad("kiln-state 1\nstep out/a\ncmd x()\nout out/a 0123456789abcde\nend\n"));
  EXPECT_TRUE(bad("kiln-state 1\nstep out/a\ncmd x()\nout out/b 0123456789abcdef\nend\n"));  // key != first out
  EXPECT_TRUE(bad("kiln-state 1\nstep out/a\ncmd x()\nout  out/a 0123456789abcdef\nend\n"));
  EXPECT_TRUE(bad("kiln-state 1\nstep out/a\ncmd x()\nout /a 0123456789abcdef\nend\n"));      // not a workspace path
  EXPECT_TRUE(bad("kiln-state 1\nstep out/a\ncmd x()\nout out/a 0123456789abcdef x\nend\n"));
  EXPECT_TRUE(bad("kiln-state 1\nstep out/a\ncmd x()\nout out/a 0123456789abcdef\nin s 0123456789abcdef\nend\n"));  // misordered
  EXPECT_TRUE(bad("kiln-state 1\nstep out/a\ncmd x()\nout out/a 0123456789abcdef\nend \n"));
  const std::string one = "step out/a\ncmd x()\nout out/a 0123456789abcdef\nend\n";
  EXPECT_TRUE(bad("kiln-state 1\n" + one + one));  // duplicate keys
  EXPECT_FALSE(bad("kiln-state 1\n" + one));
  EXPECT_EQ(BuildState::parse("kiln-state 1\n").size(), 0u);
}

TEST(State, EntriesNeedNotBeSortedOnRead) {
  std::string text =
      "kiln-state 1\nstep out/b\ncmd x()\nout out/b 0123456789abcdef\nend\n"
      "step out/a\ncmd x()\nout out/a 0123456789abcdef\nend\n";
  BuildState s = BuildState::parse(text);
  EXPECT_EQ(s.size(), 2u);
  EXPECT_EQ(s.serialize().find("step out/a"), std::string("kiln-state 1\n").size());
}
