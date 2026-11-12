#include <gtest/gtest.h>

#include "test_util.hpp"

using namespace kiln;

namespace {
// Runs one command on a single input and returns its output.
std::string run(const std::string& name, std::vector<Value> args, const std::string& input) {
  Step st;
  st.call = CommandCall{name, std::move(args)};
  st.inputs = {"in.txt"};
  Vfs vfs = kiln::testing::makeVfs({{"in.txt", input}});
  return runCommand(st, {vfs.read("in.txt")}, vfs).output;
}
Value S(const char* s) { return Value::string(s); }
}  // namespace

TEST(Commands, Lines) {
  auto lines = splitLines("a\n\nb");
  ASSERT_EQ(lines.size(), 3u);
  EXPECT_EQ(splitLines("").size(), 0u);
  EXPECT_EQ(splitLines("\n").size(), 1u);
  EXPECT_EQ(splitLines("a\r\nb\n").front(), "a\r");
}

TEST(Commands, SimpleTransforms) {
  EXPECT_EQ(run("copy", {}, "x\ny"), "x\ny");
  EXPECT_EQ(run("upper", {}, "aB\xc3\xa9"), "AB\xc3\xa9");
  EXPECT_EQ(run("lower", {}, "AbC"), "abc");
  EXPECT_EQ(run("grep", {S("b")}, "ab\nc\nbb\n"), "ab\nbb\n");
  EXPECT_EQ(run("grep", {S("")}, "a\nb"), "a\nb\n");
  EXPECT_EQ(run("replace", {S("aa"), S("b")}, "aaa"), "ba");
  EXPECT_EQ(run("sort_lines", {}, "b\na\nc"), "a\nb\nc\n");
  EXPECT_EQ(run("reverse_lines", {}, "1\n2\n3\n"), "3\n2\n1\n");
  EXPECT_EQ(run("dedup", {}, "a\nb\na\nb\nc"), "a\nb\nc\n");
  EXPECT_EQ(run("number", {}, "a\nb\nc\n"), "1: a\n2: b\n3: c\n");
  EXPECT_EQ(run("indent", {Value::integer(2)}, "a\n\nb"), "  a\n  \n  b\n");
  EXPECT_EQ(run("wrap", {S("<"), S(">")}, "x"), "<x>");
}

TEST(Commands, CountLinesAndHash) {
  Step st;
  st.call = CommandCall{"count_lines", {}};
  st.inputs = {"a", "b"};
  Vfs vfs = kiln::testing::makeVfs({{"a", "1\n2\n"}, {"b", ""}});
  EXPECT_EQ(runCommand(st, {vfs.read("a"), vfs.read("b")}, vfs).output, "2 a\n0 b\n2 total\n");
  st.call = CommandCall{"hash", {}};
  st.inputs = {"b"};
  EXPECT_EQ(runCommand(st, {vfs.read("b")}, vfs).output.substr(0, 17), "cbf29ce484222325 ");
}

TEST(Commands, CanonicalRendering) {
  EXPECT_EQ(canonicalCommand({"write", {S("hello\n")}}), "write(\"hello\\n\")");
  EXPECT_EQ(canonicalCommand({"replace", {S("a\\b"), S("c")}}), "replace(\"a\\\\b\", \"c\")");
  EXPECT_EQ(canonicalCommand({"indent", {Value::integer(4)}}), "indent(4)");
  EXPECT_EQ(canonicalCommand({"grep", {S("\x01\x7f\"\xc3\xbc")}}), "grep(\"\\x01\\x7f\\\"\xc3\xbc\")");
  EXPECT_EQ(canonicalCommand({"preprocess", {}}), "preprocess()");
}

TEST(Commands, Preprocess) {
  Vfs vfs = kiln::testing::makeVfs({{"main.txt", "title\n@need part.txt\nend\n"},
                                    {"part.txt", "PART\n@need deep.txt"},
                                    {"deep.txt", "DEEP\n"}});
  Step st;
  st.call = CommandCall{"preprocess", {}};
  st.inputs = {"main.txt"};
  CommandResult r = runCommand(st, {vfs.read("main.txt")}, vfs);
  EXPECT_EQ(r.output, "title\nPART\nDEEP\nend\n");
  EXPECT_EQ(*r.depfile, "kiln-deps 1\nneed deep.txt\nneed part.txt\n");
  EXPECT_EQ(r.discovered, (std::vector<std::string>{"deep.txt", "part.txt"}));
}

TEST(Commands, PreprocessErrors) {
  Step st;
  st.call = CommandCall{"preprocess", {}};
  st.inputs = {"m"};
  auto fail = [&](const std::string& content, std::initializer_list<std::pair<std::string, std::string>> extra) {
    Vfs vfs = kiln::testing::makeVfs(extra);
    vfs.write("m", content);
    try {
      runCommand(st, {vfs.read("m")}, vfs);
    } catch (const Error& e) {
      return e.message();
    }
    return std::string("no error");
  };
  EXPECT_EQ(fail("@need ../x\n", {}), "E_NEED_PATH ../x");
  EXPECT_EQ(fail("@need gone\n", {}), "E_NEED_MISSING gone needed by m");
  EXPECT_EQ(fail("@need a\n", {{"a", "@need a\n"}}), "E_NEED_CYCLE a");
  EXPECT_EQ(fail("@need m\n", {}), "E_NEED_CYCLE m");
  EXPECT_EQ(fail("@need \nplain @need x\n", {}), "no error");  // empty remainder is an ordinary line
}
