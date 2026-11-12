#include <gtest/gtest.h>

#include <map>
#include <string>

#include "jsoncanon/jsoncanon.hpp"

using namespace jsoncanon;

TEST(Canonicalize, WorkedExamples) {
  EXPECT_EQ(canonicalize(R"({ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null })"),
            std::string(R"({"a":"héllo/","b":null})"));
  EXPECT_EQ(canonicalize(R"(["😀", -0, 1e-007, 0.0, 1e-0, "tab\tquote\"nul\u0000 A\u0041"])"),
            std::string(R"(["😀",-0,1e-7,0.0,1e0,"tab\tquote\"nul\u0000 AA"])"));
}

TEST(Canonicalize, Invalid) {
  EXPECT_EQ(canonicalize("[1, 2, ]"), std::nullopt);
  EXPECT_EQ(canonicalize(""), std::nullopt);
}

TEST(Canonicalize, IsIdempotent) {
  const auto once = canonicalize(R"( {"z": [1E2, {"b":1,"a":[]}], "y": "\u00e9\ud83d\ude00"} )");
  ASSERT_TRUE(once);
  EXPECT_EQ(canonicalize(*once), once);
}

TEST(Canonicalize, ManyKeysMatchesReferenceOrdering) {
  // ASCII keys: byte order equals UTF-16 order, so std::map is a reference.
  std::string in = "{";
  std::map<std::string, int> ref;
  for (int i = 0; i < 20000; ++i) {
    const std::string key = "k" + std::to_string((i * 7919) % 5000);  // many duplicates
    if (i) in += ",";
    in += "\"" + key + "\":" + std::to_string(i);
    ref[key] = i;  // last wins
  }
  in += "}";
  std::string expected = "{";
  for (const auto& [k, v] : ref) {
    if (expected.size() > 1) expected += ",";
    expected += "\"" + k + "\":" + std::to_string(v);
  }
  expected += "}";
  EXPECT_EQ(canonicalize(in), expected);
}
