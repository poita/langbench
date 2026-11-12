#include <gtest/gtest.h>

#include "test_util.hpp"

using namespace kiln;

namespace {
const char* kValid =
    "kiln-state 1\nstep out/a\ncmd write(\"x y\")\nin src/a 0000000000000001\n"
    "dep src/d 0000000000000002\nout out/a 0000000000000003\nend\n";
}

TEST(State, RoundTrip) {
  BuildState s = BuildState::parse(kValid);
  ASSERT_EQ(s.size(), 1u);
  EXPECT_EQ(s.serialize(), kValid);
  EXPECT_EQ(s.find("out/a")->cmd, "write(\"x y\")");
}

TEST(State, MalformedStatesAreEmpty) {
  const std::string valid = kValid;
  for (const std::string& bad : std::vector<std::string>{
           "",
           "kiln-state 2\n",
           "kiln-state 1",                                    // no trailing newline
           valid.substr(0, valid.size() - 1),                 // unterminated last line
           valid + "stray\n",
           "kiln-state 1\nstep out/a\nout out/a 0000000000000003\nend\n",  // no cmd
           "kiln-state 1\nstep out/a\ncmd \nout out/a 0000000000000003\nend\n",
           "kiln-state 1\nstep out/a\ncmd x\nend\n",           // no out
           "kiln-state 1\nstep out/a\ncmd x\nout out/b 0000000000000003\nend\n",  // key mismatch
           "kiln-state 1\nstep out/a\ncmd x\nout out/a 000000000000000G\nend\n",
           "kiln-state 1\nstep out/a\ncmd x\nout out/a 000000000000000A\nend\n",  // uppercase hex
           "kiln-state 1\nstep out/a\ncmd x\nout out/a 0000000000000003\ncmd y\nend\n",
           "kiln-state 1\nstep out/a\ncmd x\nout out/a 0000000000000003\nin a 0000000000000003\nend\n",  // misordered
           "kiln-state 1\nstep out/a\ncmd x\nout out/a 0000000000000003\nend\n"
           "step out/a\ncmd x\nout out/a 0000000000000003\nend\n",  // duplicate key
           "kiln-state 1\nstep ../a\ncmd x\nout ../a 0000000000000003\nend\n"}) {
    EXPECT_EQ(BuildState::parse(bad).size(), 0u) << bad;
  }
}

TEST(State, UnsortedEntriesAreAcceptedAndWrittenSorted) {
  BuildState s = BuildState::parse(
      "kiln-state 1\nstep out/b\ncmd x\nout out/b 0000000000000001\nend\n"
      "step out/a\ncmd x\nout out/a 0000000000000001\nend\n");
  ASSERT_EQ(s.size(), 2u);
  EXPECT_LT(s.serialize().find("step out/a"), s.serialize().find("step out/b"));
}

TEST(State, FreshnessRules) {
  Vfs vfs = kiln::testing::makeVfs({{"src/a", "A\n"}, {"out/a", "A\n"}});
  Step st;
  st.outputs = {"out/a"};
  st.inputs = {"src/a"};
  st.canonical = "copy()";
  const std::string h = toHex16(fnv1a("A\n"));
  auto state = [&](const std::string& body) { return BuildState::parse("kiln-state 1\n" + body + "end\n"); };
  const std::string base = "step out/a\ncmd copy()\nin src/a " + h + "\nout out/a " + h + "\n";
  EXPECT_TRUE(isFresh(st, state(base), vfs));
  EXPECT_FALSE(isFresh(st, BuildState{}, vfs));
  EXPECT_FALSE(isFresh(st, state("step out/a\ncmd upper()\nin src/a " + h + "\nout out/a " + h + "\n"), vfs));
  EXPECT_FALSE(isFresh(st, state("step out/a\ncmd copy()\nout out/a " + h + "\n"), vfs));
  vfs.write("out/a", "tampered\n");
  EXPECT_FALSE(isFresh(st, state(base), vfs));
  vfs.write("out/a", "A\n");
  vfs.remove("src/a");
  EXPECT_FALSE(isFresh(st, state(base), vfs));
}
