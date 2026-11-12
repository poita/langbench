#include <gtest/gtest.h>

#include <sstream>

#include "textbuffer/script.hpp"

using namespace textbuffer;

namespace {

std::string run(const std::string& input, std::size_t* skipped = nullptr) {
    std::ostringstream out, err;
    const auto n = runScript(input, out, &err);
    if (skipped) *skipped = n;
    return out.str();
}

}  // namespace

TEST(Script, SpecExampleOne) {
    const std::string in =
        "2\nhello world\nsecond line\nmove end\ninsert !\nmove down\ninsert  (edited)\n"
        "goto 0 5\ninsert ,\nprint\ndelete\ndelete\nprint\n";
    EXPECT_EQ(run(in),
              "hello, world!\nsecond line (edited)\ncursor 0 6\n--\n"
              "hell world!\nsecond line (edited)\ncursor 0 4\n--\n");
}

TEST(Script, SpecExampleTwo) {
    const std::string in =
        "3\nalpha\nbeta\ngamma\nadd-cursor 1 0\nadd-cursor 2 0\ninsert - \nprint\n"
        "move end select\ninsert X\nprint\ngoto 0 1\nmove right select\nmove right select\n"
        "delete\nprint";
    EXPECT_EQ(run(in),
              "- alpha\n- beta\n- gamma\ncursor 0 2\ncursor 1 2\ncursor 2 2\n--\n"
              "- X\n- X\n- X\ncursor 0 3\ncursor 1 3\ncursor 2 3\n--\n"
              "-\n- X\n- X\ncursor 0 1\n--\n");
}

TEST(Script, SpecExampleThree) {
    const std::string in =
        "1\nabc\nmove end\ninsert d\\ne\nprint\ndelete\ndelete\nprint\nundo\nprint\nundo\nprint\n"
        "redo\nprint\ninsert Z\nredo\nprint\n";
    EXPECT_EQ(run(in),
              "abcd\ne\ncursor 1 1\n--\nabcd\ncursor 0 4\n--\nabcd\n\ncursor 1 0\n--\n"
              "abcd\ne\ncursor 1 1\n--\nabcd\n\ncursor 1 0\n--\nabcd\nZ\ncursor 1 1\n--\n");
}

TEST(Script, DocumentLinesAreVerbatim) {
    // A document line may look like a command, and keeps its spaces.
    EXPECT_EQ(run("3\nprint\n  x \n\nprint\n"),
              "print\n  x \n\ncursor 0 0\n--\n");
}

TEST(Script, ZeroLinesIsOneEmptyLine) {
    EXPECT_EQ(run("0\ninsert a\nprint\n"), "a\ncursor 0 1\n--\n");
}

TEST(Script, NoPrintNoOutput) { EXPECT_EQ(run("1\nabc\nmove end\n"), ""); }

TEST(Script, InvalidCommandsAreSkipped) {
    std::size_t skipped = 0;
    EXPECT_EQ(run("1\na\nbogus\nprint\n", &skipped), "a\ncursor 0 0\n--\n");
    EXPECT_EQ(skipped, 1u);
}
