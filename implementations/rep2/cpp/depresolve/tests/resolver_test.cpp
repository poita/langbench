#include <gtest/gtest.h>

#include <string>

#include "depresolve/depresolve.hpp"

using namespace depresolve;

TEST(Resolver, EmptyRootGivesEmptyOutput) { EXPECT_EQ(resolve_text("root:\n"), ""); }

TEST(Resolver, MissingPackageIsUnsatisfiable) {
  EXPECT_EQ(resolve_text("root: nope *\n"), "unsatisfiable\n");
  EXPECT_EQ(resolve_text("a 1.0.0: nope *\nroot: a *\n"), "unsatisfiable\n");
}

TEST(Resolver, PicksNewestNumerically) {
  EXPECT_EQ(resolve_text("a 1.9.0:\na 1.10.0:\na 1.2.0:\nroot: a *\n"), "a 1.10.0\n");
}

TEST(Resolver, SpecExample1DiamondBacktracking) {
  EXPECT_EQ(resolve_text("a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\n"
                         "root: a *, b *\n"),
            "a 1.0.0\nb 1.0.0\nc 1.2.5\n");
}

TEST(Resolver, SpecExample2FirstSolutionNotGlobalNewest) {
  EXPECT_EQ(resolve_text("a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\n"
                         "root: a *, b *\n"),
            "a 2.0.0\nb 1.0.5\n");
}

TEST(Resolver, SpecExample3Conflict) {
  EXPECT_EQ(resolve_text("a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n"),
            "unsatisfiable\n");
}

TEST(Resolver, SpecExample4RequirementOrderMatters) {
  const std::string registry =
      "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\n";
  EXPECT_EQ(resolve_text(registry + "root: a *, b *\n"), "a 2.0.0\nb 1.0.0\nc 2.0.0\n");
  EXPECT_EQ(resolve_text(registry + "root: b *, a *\n"), "a 1.0.0\nb 2.0.0\nc 1.0.0\n");
}

TEST(Resolver, CyclesAndSelfRequirements) {
  EXPECT_EQ(resolve_text("a 1.0.0: b *\nb 1.0.0: a *\nroot: a *\n"), "a 1.0.0\nb 1.0.0\n");
  EXPECT_EQ(resolve_text("a 2.0.0: a ^1.0.0\na 1.0.0: a *\nroot: a *\n"), "a 1.0.0\n");
}

TEST(Resolver, EmptyComparatorRange) {
  EXPECT_EQ(resolve_text("a 1.0.0:\nroot: a >=2.0.0 <1.0.0\n"), "unsatisfiable\n");
}

TEST(Resolver, OutputSortedByByteOrder) {
  EXPECT_EQ(resolve_text("mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\nroot: mylib *, my-lib2 *, my-lib *\n"),
            "my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0\n");
}

TEST(Resolver, UnchosenVersionsRequirementsAreIrrelevant) {
  // a 2.0.0 needs a package that does not exist; a 1.0.0 is picked after backtracking.
  EXPECT_EQ(resolve_text("a 2.0.0: ghost *\na 1.0.0:\nroot: a *\n"), "a 1.0.0\n");
}

TEST(Resolver, ChronologicalBacktrackingRevisitsUnrelatedPackage) {
  // z is chosen last-before-failure; q (unrelated) must be retried before p fails over.
  const std::string text =
      "p 2.0.0: q *\np 1.0.0: q *\nq 2.0.0:\nq 1.0.0:\nr 1.0.0: q 1.0.0\nroot: p *, r *\n";
  EXPECT_EQ(resolve_text(text), "p 2.0.0\nq 1.0.0\nr 1.0.0\n");
}

TEST(Resolver, ReportsStats) {
  const Problem p = parse_problem("a 1.0.0:\nroot: a *\n");
  const Resolution r = resolve(p);
  EXPECT_TRUE(r.satisfiable);
  EXPECT_EQ(r.stats.steps, 1u);
  EXPECT_EQ(r.stats.choice_points, 1u);
  ASSERT_EQ(r.picks.size(), 1u);
  EXPECT_EQ(r.picks[0].name, "a");
}

TEST(Resolver, DeepChainDoesNotOverflowTheStack) {
  constexpr int kDepth = 20000;
  std::string text;
  for (int i = 0; i < kDepth; ++i) {
    text += "p" + std::to_string(i) + " 1.0.0: p" + std::to_string(i + 1) + " *\n";
  }
  text += "p" + std::to_string(kDepth) + " 1.0.0:\nroot: p0 *\n";
  const Problem p = parse_problem(text);
  const Resolution r = resolve(p);
  EXPECT_TRUE(r.satisfiable);
  EXPECT_EQ(r.picks.size(), static_cast<std::size_t>(kDepth + 1));
}

TEST(Resolver, ManyVersionsStepDown) {
  std::string text;
  for (int i = 1; i <= 1600; ++i) text += "a 1." + std::to_string(i) + ".0:\n";
  text += "root: a <1.5.0\n";
  EXPECT_EQ(resolve_text(text), "a 1.4.0\n");
}

TEST(Resolver, RequiresFinalizedRegistry) {
  Registry r;
  r.add_version("a", Version{1, 0, 0}, {});
  EXPECT_THROW(resolve(r, std::vector<Dependency>{{"a", Range::any()}}), std::logic_error);
}
