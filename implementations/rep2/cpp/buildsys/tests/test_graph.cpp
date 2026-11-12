#include <gtest/gtest.h>

#include "test_util.hpp"

using namespace kiln;

namespace {
std::string buildError(Vfs& vfs, std::vector<std::string> targets = {}) {
  BuildReport r = runBuild(vfs, targets, 1);
  return r.error ? r.error->message() : "";
}
std::string step(const std::string& out, const std::string& in, const std::string& cmd) {
  return "step {\n out \"out/" + out + "\"\n " + in + "\n cmd " + cmd + "\n}\n";
}
}  // namespace

TEST(Graph, DuplicateOutputs) {
  Vfs vfs = kiln::testing::makeVfs({{"main.kiln", step("z", "", "write(\"1\")") + step("z", "", "write(\"2\")") + "default \"out/z\"\n"}});
  EXPECT_EQ(buildError(vfs), "E_DUP_OUTPUT out/z");
}

TEST(Graph, DepfileCountsAsOutput) {
  Vfs vfs = kiln::testing::makeVfs({{"main.kiln",
      "step {\n out \"out/a\"\n depfile \"out/a.d\"\n in \"s\"\n cmd preprocess()\n}\n" +
      step("a.d", "", "write(\"x\")") + "default \"out/a\"\n"}, {"s", ""}});
  EXPECT_EQ(buildError(vfs), "E_DUP_OUTPUT out/a.d");
}

TEST(Graph, MissingInputAndUnknownTarget) {
  Vfs vfs = kiln::testing::makeVfs({{"main.kiln", step("a", "in \"nope\"", "copy()") + "default \"out/a\"\n"}});
  EXPECT_EQ(buildError(vfs), "E_MISSING_INPUT nope required by out/a");
  vfs.write("main.kiln", "phony p = [\"@q\"]\ndefault \"@p\"\n");
  EXPECT_EQ(buildError(vfs), "E_MISSING_INPUT @q required by @p");
  vfs.write("main.kiln", step("a", "", "write(\"\")") + "default \"out/nope\"\n");
  EXPECT_EQ(buildError(vfs), "E_UNKNOWN_TARGET out/nope");
  EXPECT_EQ(buildError(vfs, {"out/a"}), "E_UNKNOWN_TARGET out/nope");  // defaults checked even with targets
  vfs.write("main.kiln", step("a", "", "write(\"\")"));
  EXPECT_EQ(buildError(vfs), "E_NO_DEFAULT");
  EXPECT_EQ(buildError(vfs, {"@bad name"}), "E_UNKNOWN_TARGET @bad name");
}

TEST(Graph, CycleReportsDfsPath) {
  Vfs vfs = kiln::testing::makeVfs({{"main.kiln",
      step("x", "in \"out/y\"", "copy()") + step("y", "in \"out/x\"", "copy()") + "default \"out/x\"\n"}});
  EXPECT_EQ(buildError(vfs), "E_CYCLE out/x -> out/y -> out/x");
  vfs.write("main.kiln", step("a", "in \"out/a\"", "copy()") + "default \"out/a\"\n");
  EXPECT_EQ(buildError(vfs), "E_CYCLE out/a -> out/a");
}

TEST(Graph, CyclesOutsideReachableSetAreIgnored) {
  Vfs vfs = kiln::testing::makeVfs({{"main.kiln",
      step("x", "in \"out/y\"", "copy()") + step("y", "in \"out/x\"", "copy()") +
      step("ok", "", "write(\"k\")") + "default \"out/ok\"\n"}});
  EXPECT_EQ(buildError(vfs), "");
}

TEST(Graph, ConfigurationErrorsLeaveWorkspaceUntouched) {
  Vfs vfs = kiln::testing::makeVfs({{"main.kiln", "abort \"x\"\n"}});
  size_t before = vfs.size();
  EXPECT_EQ(buildError(vfs), "E_ABORT x");
  EXPECT_EQ(vfs.size(), before);
  EXPECT_FALSE(vfs.exists(".kiln-state"));
}
