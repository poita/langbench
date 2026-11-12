#include <gtest/gtest.h>

#include <stdexcept>

#include "depresolve/registry.hpp"

using namespace depresolve;

namespace {
Version V(const char* s) { return *Version::parse(s); }
Dependency D(const char* name, const char* range) { return {name, *Range::parse(range)}; }
}  // namespace

TEST(Registry, SortsNewestFirstNumerically) {
  Registry r;
  for (const char* v : {"1.9.0", "1.10.0", "1.2.0", "2.0.0"}) r.add_version("p", V(v), {});
  r.finalize();
  const auto& versions = r.versions(*r.find("p"));
  ASSERT_EQ(versions.size(), 4u);
  EXPECT_EQ(versions[0].version, V("2.0.0"));
  EXPECT_EQ(versions[1].version, V("1.10.0"));
  EXPECT_EQ(versions[2].version, V("1.9.0"));
  EXPECT_EQ(versions[3].version, V("1.2.0"));
}

TEST(Registry, CompilesRequirementsToIndexRanges) {
  Registry r;
  for (const char* v : {"1.0.0", "1.1.0", "1.2.5", "1.3.0", "2.0.0"}) r.add_version("c", V(v), {});
  r.add_version("a", V("1.0.0"), {D("c", "^1.0.0"), D("c2", "*")});
  r.finalize();
  const auto& reqs = r.versions(*r.find("a"))[0].requirements;
  ASSERT_EQ(reqs.size(), 2u);
  // newest first: 2.0.0, 1.3.0, 1.2.5, 1.1.0, 1.0.0 -> ^1.0.0 is indices [1,5)
  EXPECT_EQ(reqs[0].first, 1u);
  EXPECT_EQ(reqs[0].last, 5u);
  EXPECT_FALSE(reqs[1].has_candidates());  // c2 has no versions
}

TEST(Registry, CompileRootRequirements) {
  Registry r;
  for (const char* v : {"1.0.0", "2.0.0", "3.0.0"}) r.add_version("x", V(v), {});
  r.finalize();
  const auto req = r.compile(D("x", ">=2.0.0"));
  EXPECT_EQ(req.first, 0u);
  EXPECT_EQ(req.last, 2u);
  EXPECT_TRUE(req.accepts_index(1));
  EXPECT_FALSE(req.accepts_index(2));
  const auto missing = r.compile(D("nope", "*"));
  EXPECT_EQ(missing.package, kNoPackage);
  EXPECT_FALSE(missing.has_candidates());
  const auto empty = r.compile(D("x", ">=3.0.0 <1.0.0"));
  EXPECT_FALSE(empty.has_candidates());
}

TEST(Registry, RangeAboveAllAndBelowAll) {
  Registry r;
  r.add_version("x", V("1.0.0"), {});
  r.add_version("x", V("2.0.0"), {});
  r.finalize();
  EXPECT_FALSE(r.compile(D("x", ">5.0.0")).has_candidates());
  EXPECT_FALSE(r.compile(D("x", "<1.0.0")).has_candidates());
  const auto all = r.compile(D("x", "*"));
  EXPECT_EQ(all.first, 0u);
  EXPECT_EQ(all.last, 2u);
}

TEST(Registry, DuplicateVersionThrows) {
  Registry r;
  r.add_version("x", V("1.0.0"), {});
  r.add_version("x", V("1.0.0"), {});
  EXPECT_THROW(r.finalize(), std::invalid_argument);
}

TEST(Registry, CompileBeforeFinalizeThrows) {
  Registry r;
  r.add_version("x", V("1.0.0"), {});
  EXPECT_THROW(r.compile(D("x", "*")), std::logic_error);
}

TEST(Registry, ForwardReferencesAndSelfReferences) {
  Registry r;
  r.add_version("a", V("1.0.0"), {D("b", "*"), D("a", "*")});
  r.add_version("b", V("1.0.0"), {});
  r.finalize();
  const auto& reqs = r.versions(*r.find("a"))[0].requirements;
  EXPECT_TRUE(reqs[0].has_candidates());
  EXPECT_EQ(reqs[1].package, *r.find("a"));
}
