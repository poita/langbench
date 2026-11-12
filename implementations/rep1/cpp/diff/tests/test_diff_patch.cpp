#include <gtest/gtest.h>

#include <random>
#include <string>

#include "mdiff/diff.hpp"
#include "mdiff/patch.hpp"
#include "oracle.hpp"

using namespace mdiff;

TEST(Diff, WhitespaceIsSignificant) {
  Lines a = {"  indented", "trailing ", "trailing", " both ", "plain"};
  Lines b = {"  indented", "trailing", "trailing ", " both", "plain", " "};
  EditScript s = diff_lines(a, b);
  EXPECT_TRUE(testutil::script_valid(s, a, b));
  EXPECT_EQ(script_cost(s), 5u);
}

TEST(Diff, LinesThatLookLikeTags) {
  Lines a = {"-", "+", " ", "5", ""};
  Lines b = {"+", "-", "", " ", "+1"};
  EditScript s = diff_lines(a, b);
  EXPECT_TRUE(testutil::script_valid(s, a, b));
  EXPECT_EQ(script_cost(s), a.size() + b.size() - 2 * testutil::lcs_length(a, b));
}

TEST(Script, RenderTagsAndText) {
  Lines a = {"x", "y"}, b = {"x", "z"};
  EditScript s = diff_lines(a, b);
  std::string r = render_script(s, a, b);
  EXPECT_EQ(r.substr(0, 3), " x\n");
  EXPECT_NE(r.find("-y\n"), std::string::npos);
  EXPECT_NE(r.find("+z\n"), std::string::npos);
}

TEST(Script, ParseLine) {
  auto k = parse_script_line("  ");
  EXPECT_EQ(k.kind, EditKind::Keep);
  EXPECT_EQ(k.text, " ");
  auto i = parse_script_line("+-x");
  EXPECT_EQ(i.kind, EditKind::Insert);
  EXPECT_EQ(i.text, "-x");
  auto d = parse_script_line("-");
  EXPECT_EQ(d.kind, EditKind::Delete);
  EXPECT_EQ(d.text, "");
  EXPECT_THROW(parse_script_line(""), ScriptError);
  EXPECT_THROW(parse_script_line("x"), ScriptError);
}

TEST(Patch, SpecExample) {
  Lines a = {"a", "b", "c", "d", "e"};
  Lines script = {" a", "-b", "+B", " c", "+c2", "-d", " e", "+f"};
  EXPECT_EQ(apply_script(a, script), (Lines{"a", "B", "c", "c2", "e", "f"}));
}

TEST(Patch, NonMinimalScript) {
  Lines a = {"a"};
  EXPECT_EQ(apply_script(a, {"-a", "+a", "+a", "+"}), (Lines{"a", "a", ""}));
}

TEST(Patch, EmptyResult) { EXPECT_TRUE(apply_script({"a"}, {"-a"}).empty()); }

TEST(Patch, RejectsInconsistentScripts) {
  EXPECT_THROW(apply_script({"a"}, {" b"}), ScriptError);
  EXPECT_THROW(apply_script({"a"}, {" a", "-b"}), ScriptError);
  EXPECT_THROW(apply_script({"a", "b"}, {" a"}), ScriptError);
  EXPECT_THROW(apply_script({"a"}, {"?a"}), ScriptError);
}

TEST(RoundTrip, DiffThenPatchReproducesB) {
  std::mt19937 rng(99);
  for (int iter = 0; iter < 300; ++iter) {
    std::vector<std::string> sa(rng() % 40), sb(rng() % 40);
    for (auto& s : sa) s = std::string(rng() % 3, ' ') + std::to_string(rng() % 5);
    for (auto& s : sb) s = std::string(rng() % 3, ' ') + std::to_string(rng() % 5);
    Lines a(sa.begin(), sa.end()), b(sb.begin(), sb.end());
    EditScript s = diff_lines(a, b);
    ASSERT_TRUE(testutil::script_valid(s, a, b));
    EXPECT_EQ(script_cost(s), a.size() + b.size() - 2 * testutil::lcs_length(a, b));
    std::string text = render_script(s, a, b);
    Lines script_lines = split_lines(text);
    EXPECT_EQ(apply_script(a, script_lines), b);
  }
}
