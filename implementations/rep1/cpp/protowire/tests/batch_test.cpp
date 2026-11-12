#include <gtest/gtest.h>

#include <string>

#include "protowire/batch.hpp"

using namespace protowire;

TEST(Batch, SpecExampleOne) {
  const std::string in =
      "message Inner { sint32 v = 1; }\n"
      "message Outer {\n  int32 a = 1;\n  string b = 2;\n  repeated int32 c = 3;\n  Inner d = 4;\n}\n"
      "--\n"
      "encode Outer {a: 1, b: \"x\", c: [1, 2], d: {v: -5}}\n"
      "decode Outer 08011201781a02010222020809\n"
      "encode Outer {d: {}, c: [], a: 0}\n"
      "decode Outer 3800\n"
      "decode Outer 08ff\n";
  EXPECT_EQ(processInput(in),
            "08011201781a02010222020809\n"
            "{a: 1, b: \"x\", c: [1, 2], d: {v: -5}}\n"
            "2200\n"
            "{}\n"
            "error\n");
}

TEST(Batch, FinalNewlineOptionalAndEmptyOutputLine) {
  const std::string in = "message M { int32 a = 1; }\n--\nencode M {}\ndecode M";
  EXPECT_EQ(processInput(in), "\n{}\n");
}

TEST(Batch, RequestFormErrors) {
  const std::string head = "message M { int32 a = 1; }\n--\n";
  auto run = [&](const std::string& line) { return processInput(head + line + "\n"); };
  EXPECT_EQ(run("decode M "), "error\n");          // trailing space
  EXPECT_EQ(run("decode M 0"), "error\n");         // odd digits
  EXPECT_EQ(run("decode M 0A01"), "error\n");      // uppercase
  EXPECT_EQ(run("decode M 0801 "), "error\n");
  EXPECT_EQ(run("decode M 0801 00"), "error\n");   // text after hex
  EXPECT_EQ(run("decode M 0801"), "{a: 1}\n");
  EXPECT_EQ(run("encode M"), "error\n");
  EXPECT_EQ(run("encode M "), "error\n");
  EXPECT_EQ(run("encode M    "), "error\n");
  EXPECT_EQ(run("encode M {a: 1} "), "0801\n");    // trailing spaces after '}' are allowed
  EXPECT_EQ(run("frobnicate M {}"), "error\n");
  EXPECT_EQ(run("decode"), "error\n");
}

TEST(Batch, SchemaOnlyUpToFirstSeparator) {
  const std::string in = "message M { string s = 1; }\n--\nencode M {s: \"--\"}\n--\n";
  EXPECT_EQ(processInput(in), "0a022d2d\nerror\n");
}

TEST(Batch, BadSchemaYieldsErrors) {
  EXPECT_EQ(processInput("message {\n--\ndecode M\n"), "error\n");
}
