#include <gtest/gtest.h>

#include "support.hpp"

using namespace kiln;

namespace {

// Runs a command on in-memory inputs and returns its output content.
std::string run_cmd(const char* name, std::vector<Value> args, std::vector<std::pair<std::string, std::string>> inputs,
                    Vfs fs = Vfs()) {
  const CommandSpec* spec = find_command(name);
  EXPECT_NE(spec, nullptr) << name;
  std::vector<CommandInput> in;
  for (auto& [p, c] : inputs) in.push_back({p, std::make_shared<const std::string>(c)});
  return run_command(*spec, args, in, fs).output;
}

Value S(const char* s) { return Value::string(s); }

}  // namespace

TEST(Commands, SixteenCommandsExist) {
  for (const char* n : {"write", "copy", "concat", "upper", "lower", "grep", "replace", "sort_lines",
                        "reverse_lines", "dedup", "number", "indent", "wrap", "count_lines", "hash", "preprocess"}) {
    EXPECT_NE(find_command(n), nullptr) << n;
  }
  EXPECT_EQ(find_command("cat"), nullptr);
  EXPECT_EQ(find_command("preprocess")->default_cost, 6);
  EXPECT_EQ(find_command("sort_lines")->default_cost, 4);
}

TEST(Commands, SplitLines) {
  EXPECT_TRUE(split_lines("").empty());
  EXPECT_EQ(split_lines("a\nb\n").size(), 2u);
  EXPECT_EQ(split_lines("a\nb").size(), 2u);
  EXPECT_EQ(split_lines("a\n\nb\n").size(), 3u);
  EXPECT_EQ(split_lines("\n").size(), 1u);
  EXPECT_EQ(split_lines("a\r\n")[0], "a\r");
}

TEST(Commands, Simple) {
  EXPECT_EQ(run_cmd("write", {S("x\0y")}, {}), "x");  // the C string stops at NUL; see below for \0
  EXPECT_EQ(run_cmd("copy", {}, {{"a", "q\r\n"}}), "q\r\n");
  EXPECT_EQ(run_cmd("concat", {}, {{"a", "1"}, {"b", "2"}, {"a", "1"}}), "121");
  EXPECT_EQ(run_cmd("upper", {}, {{"a", "aZ\xc3\xbc"}}), "AZ\xc3\xbc");
  EXPECT_EQ(run_cmd("lower", {}, {{"a", "aZ\xc3\x9c"}}), "az\xc3\x9c");
  EXPECT_EQ(run_cmd("wrap", {S("<"), S(">")}, {{"a", "mid"}}), "<mid>");
  EXPECT_EQ(run_cmd("replace", {S("aa"), S("b")}, {{"a", "aaaa\naa"}}), "bb\nb");
}

TEST(Commands, LineOriented) {
  EXPECT_EQ(run_cmd("grep", {S("b")}, {{"a", "abc\nxyz\nb"}}), "abc\nb\n");
  EXPECT_EQ(run_cmd("grep", {S("")}, {{"a", "x\ny"}}), "x\ny\n");
  EXPECT_EQ(run_cmd("sort_lines", {}, {{"a", "b\na\n\xc3\xbc\nB\n"}}), "B\na\nb\n\xc3\xbc\n");
  EXPECT_EQ(run_cmd("reverse_lines", {}, {{"a", "1\n2\n3"}}), "3\n2\n1\n");
  EXPECT_EQ(run_cmd("dedup", {}, {{"a", "a\nb\na\nc\nb\n"}}), "a\nb\nc\n");
  EXPECT_EQ(run_cmd("number", {}, {{"a", "a\n\nc"}}), "1: a\n2: \n3: c\n");
  EXPECT_EQ(run_cmd("indent", {Value::integer(2)}, {{"a", "a\n\nb\n"}}), "  a\n  \n  b\n");
  EXPECT_EQ(run_cmd("indent", {Value::integer(3)}, {{"a", ""}}), "");
}

TEST(Commands, CountLinesAndHash) {
  EXPECT_EQ(run_cmd("count_lines", {}, {{"src/a.txt", "x\ny\n"}, {"src/b.txt", ""}}), "2 src/a.txt\n0 src/b.txt\n2 total\n");
  EXPECT_EQ(run_cmd("hash", {}, {{"p", "hello\n"}, {"p", "hello\n"}}),
            "a9bc80cca21f28b3 p\na9bc80cca21f28b3 p\n");
}

TEST(Commands, CanonicalStrings) {
  auto canon = [](const char* name, std::vector<Value> args) { return canonical_command(*find_command(name), args); };
  EXPECT_EQ(canon("write", {S("hello\n")}), "write(\"hello\\n\")");
  EXPECT_EQ(canon("replace", {S("a\\b"), S("c")}), "replace(\"a\\\\b\", \"c\")");
  EXPECT_EQ(canon("indent", {Value::integer(4)}), "indent(4)");
  EXPECT_EQ(canon("wrap", {S("<<"), S(">>")}), "wrap(\"<<\", \">>\")");
  EXPECT_EQ(canon("grep", {S("\xc3\xbc")}), "grep(\"\xc3\xbc\")");
  EXPECT_EQ(canon("preprocess", {}), "preprocess()");
  EXPECT_EQ(canon("write", {Value::string(std::string("\x01\x7f\t\r\"", 5))}), "write(\"\\x01\\x7f\\t\\r\\\"\")");
}

TEST(Preprocess, ExpandsAndRecordsDiscoveredFiles) {
  Vfs fs = testing_support::workspace({{"src/part.txt", "PART\n@need src/deep.txt\n"}, {"src/deep.txt", "DEEP\n"}});
  const CommandSpec* spec = find_command("preprocess");
  std::vector<CommandInput> in{{"src/main.txt", std::make_shared<const std::string>("title\n@need src/part.txt\n@need src/deep.txt\nend")}};
  CommandResult r = run_command(*spec, {}, in, fs);
  EXPECT_EQ(r.output, "title\nPART\nDEEP\nDEEP\nend\n");
  EXPECT_EQ(r.depfile, "kiln-deps 1\nneed src/deep.txt\nneed src/part.txt\n");
  EXPECT_EQ(r.discovered, (std::vector<std::string>{"src/deep.txt", "src/part.txt"}));
}

TEST(Preprocess, DirectiveRules) {
  Vfs fs = testing_support::workspace({{"x", "X\n"}});
  const CommandSpec* spec = find_command("preprocess");
  auto go = [&](const std::string& body) {
    std::vector<CommandInput> in{{"main", std::make_shared<const std::string>(body)}};
    try {
      return run_command(*spec, {}, in, fs).output;
    } catch (const Error& e) {
      return e.text();
    }
  };
  EXPECT_EQ(go("@need x\n"), "X\n");
  EXPECT_EQ(go("@need \n"), "@need \n");   // empty remainder: an ordinary line
  EXPECT_EQ(go("@need\n"), "@need\n");      // no trailing space: an ordinary line
  EXPECT_EQ(go(" @need x\n"), " @need x\n");
  EXPECT_EQ(go("@need x \n"), "E_NEED_PATH x ");  // remainder is not trimmed
  EXPECT_EQ(go("@need ../x\n"), "E_NEED_PATH ../x");
  EXPECT_EQ(go("@need gone\n"), "E_NEED_MISSING gone needed by main");
  EXPECT_EQ(go("@need main\n"), "E_NEED_MISSING main needed by main");  // not in the workspace
}

TEST(Preprocess, CycleDetection) {
  Vfs fs = testing_support::workspace({{"a", "@need b\n"}, {"b", "@need a\n"}});
  const CommandSpec* spec = find_command("preprocess");
  std::vector<CommandInput> in{{"a", fs.read("a")}};
  try {
    run_command(*spec, {}, in, fs);
    FAIL() << "expected a cycle";
  } catch (const Error& e) {
    EXPECT_EQ(e.text(), "E_NEED_CYCLE a");
  }
}
