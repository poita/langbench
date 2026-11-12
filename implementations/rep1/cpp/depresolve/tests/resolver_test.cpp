#include <gtest/gtest.h>

#include <string>

#include "depresolve/output.hpp"
#include "depresolve/parser.hpp"
#include "depresolve/resolver.hpp"

using namespace depresolve;

namespace {
std::string run(const std::string& input) {
  return format_resolution(resolve(parse_problem(input)));
}
}  // namespace

TEST(Resolver, EmptyRootGivesEmptyOutput) { EXPECT_EQ(run("root:\n"), ""); }

TEST(Resolver, MissingPackageIsUnsatisfiable) {
  EXPECT_EQ(run("root: a *\n"), "unsatisfiable\n");
  EXPECT_EQ(run("a 1.0.0:\nroot: a ^2.0.0\n"), "unsatisfiable\n");
}

TEST(Resolver, PicksNewestMatching) {
  EXPECT_EQ(run("a 1.9.0:\na 1.10.0:\na 2.0.0:\nroot: a ^1.0.0\n"), "a 1.10.0\n");
}

TEST(Resolver, DiamondNeedsBacktracking) {
  EXPECT_EQ(run("a 1.0.0: c ^1.0.0\n"
                "b 1.0.0: c ~1.2.0\n"
                "c 1.1.0:\nc 1.2.5:\nc 1.3.0:\n"
                "root: a *, b *\n"),
            "a 1.0.0\nb 1.0.0\nc 1.2.5\n");
}

TEST(Resolver, FirstSolutionNotGloballyNewest) {
  EXPECT_EQ(run("a 2.0.0: b ~1.0.0\na 1.0.0:\n"
                "b 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\n"
                "root: a *, b *\n"),
            "a 2.0.0\nb 1.0.5\n");
}

TEST(Resolver, ConflictingMajors) {
  EXPECT_EQ(run("a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n"),
            "unsatisfiable\n");
}

TEST(Resolver, RequirementOrderMatters) {
  const std::string registry =
      "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\n"
      "b 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\n"
      "c 1.0.0:\nc 2.0.0:\n";
  EXPECT_EQ(run(registry + "root: a *, b *\n"), "a 2.0.0\nb 1.0.0\nc 2.0.0\n");
  EXPECT_EQ(run(registry + "root: b *, a *\n"), "a 1.0.0\nb 2.0.0\nc 1.0.0\n");
}

TEST(Resolver, CyclesAndSelfRequirement) {
  EXPECT_EQ(run("a 1.0.0: b *, a *\nb 1.0.0: a *\nroot: a *\n"), "a 1.0.0\nb 1.0.0\n");
  // Self requirement that the chosen version itself fails to satisfy.
  EXPECT_EQ(run("a 2.0.0: a ^1.0.0\na 1.0.0:\nroot: a *\n"), "a 1.0.0\n");
}

TEST(Resolver, UnrelatedPackageIsRetriedChronologically) {
  // x is chosen before the conflict on y; backtracking steps x down first,
  // which does not help, and the search ends up unsatisfiable only after
  // exhausting x's candidates.
  Problem p = parse_problem(
      "x 1.0.0:\nx 2.0.0:\nx 3.0.0:\ny 1.0.0:\nroot: x *, y ^2.0.0\n");
  Resolver r(p.registry, p.root);
  EXPECT_FALSE(r.resolve());
  EXPECT_EQ(r.stats().choices, 3u);
}

TEST(Resolver, OutputSortedByByteOrder) {
  EXPECT_EQ(run("mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\nroot: mylib *, my-lib2 *, my-lib *\n"),
            "my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0\n");
}

TEST(Resolver, UnchosenVersionRequirementsIgnored) {
  EXPECT_EQ(run("a 2.0.0:\na 1.0.0: missing *\nroot: a *\n"), "a 2.0.0\n");
}

TEST(Resolver, EmptyRangeYieldsNoCandidates) {
  EXPECT_EQ(run("a 1.0.0:\nroot: a >=2.0.0 <1.0.0\n"), "unsatisfiable\n");
}

TEST(Resolver, ResolveIsRepeatable) {
  Problem p = parse_problem("a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n");
  Resolver r(p.registry, p.root);
  auto first = r.resolve();
  auto second = r.resolve();
  ASSERT_TRUE(first && second);
  EXPECT_EQ(format_resolution(first), format_resolution(second));
}

TEST(Resolver, DeepChainDoesNotOverflowStack) {
  const int n = 20000;
  std::string input;
  for (int i = 0; i < n; ++i) {
    input += "p" + std::to_string(i) + " 1.0.0: p" + std::to_string(i + 1) + " *\n";
  }
  input += "p" + std::to_string(n) + " 1.0.0:\nroot: p0 *\n";
  Problem p = parse_problem(input);
  auto result = resolve(p);
  ASSERT_TRUE(result);
  EXPECT_EQ(result->packages.size(), static_cast<std::size_t>(n + 1));
}

TEST(Resolver, ManyVersionsStepDown) {
  std::string input;
  for (int i = 1; i <= 1000; ++i) input += "a " + std::to_string(i) + ".0.0:\n";
  input += "root: a *, a <=3.0.0\n";
  EXPECT_EQ(run(input), "a 3.0.0\n");
  std::string input2;
  for (int i = 1; i <= 1000; ++i) input2 += "a " + std::to_string(i) + ".0.0:\n";
  input2 += "b 1.0.0: a <=3.0.0\nroot: a *, b *\n";
  EXPECT_EQ(run(input2), "a 3.0.0\nb 1.0.0\n");
}
