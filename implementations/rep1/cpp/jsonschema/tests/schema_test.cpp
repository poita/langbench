#include <gtest/gtest.h>

#include "jsonschema/schema.hpp"

using namespace jsonschema;

namespace {

bool Valid(const char* schema, const char* instance) {
  return Schema::compile_json(schema).is_valid(parse_json(instance));
}

bool ValidWithRemotes(const char* schema, std::vector<std::pair<std::string, std::string>> remotes,
                      const char* instance) {
  std::vector<Remote> rs;
  for (auto& [uri, text] : remotes) rs.emplace_back(uri, parse_json(text));
  return Schema::compile(parse_json(schema), std::move(rs)).is_valid(parse_json(instance));
}

}  // namespace

TEST(Schema, BooleanSchemas) {
  EXPECT_TRUE(Valid("true", "1"));
  EXPECT_FALSE(Valid("false", "1"));
  EXPECT_TRUE(Valid("{}", "[1,2]"));
}

TEST(Schema, TypeKeyword) {
  EXPECT_TRUE(Valid(R"({"type":"integer"})", "1.0"));
  EXPECT_FALSE(Valid(R"({"type":"integer"})", "1.5"));
  EXPECT_TRUE(Valid(R"({"type":"number"})", "1.5"));
  EXPECT_FALSE(Valid(R"({"type":"number"})", "true"));
  EXPECT_TRUE(Valid(R"({"type":["string","null"]})", "null"));
  EXPECT_FALSE(Valid(R"({"type":["string","null"]})", "1"));
}

TEST(Schema, EnumAndConstUseJsonEquality) {
  const char* s = R"({"enum":[1,"1",null,[1],{"a":1}]})";
  EXPECT_TRUE(Valid(s, "1"));
  EXPECT_TRUE(Valid(s, "1.0"));
  EXPECT_TRUE(Valid(s, R"({"a":1.000})"));
  EXPECT_FALSE(Valid(s, "true"));
  EXPECT_FALSE(Valid(s, "false"));
  EXPECT_FALSE(Valid(s, "[2]"));
  EXPECT_TRUE(Valid(R"({"const":0})", "-0"));
  EXPECT_FALSE(Valid(R"({"const":0})", "false"));
}

TEST(Schema, NumericKeywordsAreExact) {
  EXPECT_TRUE(Valid(R"({"multipleOf":0.0001})", "0.3"));
  EXPECT_TRUE(Valid(R"({"multipleOf":0.0001})", "0.0021"));
  EXPECT_FALSE(Valid(R"({"multipleOf":0.0001})", "0.00011"));
  EXPECT_TRUE(Valid(R"({"maximum":1e308})", "1e308"));
  EXPECT_FALSE(Valid(R"({"maximum":1e308})", "1e309"));
  EXPECT_FALSE(Valid(R"({"exclusiveMinimum":0})", "0"));
  EXPECT_TRUE(Valid(R"({"minimum":0})", "-0"));
  EXPECT_TRUE(Valid(R"({"minimum":1})", "\"inert\""));
}

TEST(Schema, StringKeywords) {
  EXPECT_TRUE(Valid(R"({"maxLength":1})", "\"\xF0\x9F\x92\xA9\""));
  EXPECT_FALSE(Valid(R"({"minLength":2})", "\"\xF0\x9F\x92\xA9\""));
  EXPECT_FALSE(Valid(R"({"minLength":2})", "\"\xC3\xA9\""));  // "é" precomposed is one code point
  EXPECT_TRUE(Valid(R"({"minLength":2})", "\"e\xCC\x81\""));    // "é" decomposed is two
  EXPECT_TRUE(Valid(R"({"pattern":"bar"})", "\"foobarbaz\""));
  EXPECT_FALSE(Valid(R"({"pattern":"^bar"})", "\"foobarbaz\""));
  EXPECT_TRUE(Valid(R"({"pattern":"^a$"})", "[1]"));
}

TEST(Schema, CountsMayBeWrittenAsFloats) {
  EXPECT_TRUE(Valid(R"({"maxItems":2.0})", "[1,2]"));
  EXPECT_FALSE(Valid(R"({"maxItems":2e0})", "[1,2,3]"));
  EXPECT_FALSE(Valid(R"({"minLength":2.0})", "\"a\""));
}

TEST(Schema, ArrayKeywords) {
  EXPECT_TRUE(Valid(R"({"uniqueItems":true})", "[1,\"1\",true]"));
  EXPECT_FALSE(Valid(R"({"uniqueItems":true})", "[1,1.0]"));
  EXPECT_FALSE(Valid(R"({"uniqueItems":true})", R"([{"a":1,"b":2},{"b":2,"a":1}])"));
  EXPECT_TRUE(Valid(R"({"prefixItems":[{"type":"integer"},{"type":"string"}],"items":false})", R"([1,"a"])"));
  EXPECT_FALSE(Valid(R"({"prefixItems":[{"type":"integer"}],"items":false})", R"([1,"a"])"));
  EXPECT_TRUE(Valid(R"({"items":{"type":"integer"}})", "[1,2,3]"));
  EXPECT_FALSE(Valid(R"({"items":{"type":"integer"}})", R"([1,"x"])"));
}

TEST(Schema, UniqueItemsLargeArrays) {
  std::string arr = "[";
  for (int i = 0; i < 20000; ++i) arr += (i ? "," : "") + std::to_string(i);
  EXPECT_TRUE(Valid(R"({"uniqueItems":true})", (arr + "]").c_str()));
  EXPECT_FALSE(Valid(R"({"uniqueItems":true})", (arr + ",5.0]").c_str()));
}

TEST(Schema, ContainsWithCounts) {
  const char* s = R"({"type":"array","contains":{"type":"integer"},"minContains":2,"maxContains":3})";
  EXPECT_TRUE(Valid(s, R"([1,"a",2])"));
  EXPECT_TRUE(Valid(s, R"(["a",1,2,3,"b"])"));
  EXPECT_FALSE(Valid(s, R"([1,"a"])"));
  EXPECT_FALSE(Valid(s, "[1,2,3,4]"));
  EXPECT_TRUE(Valid(R"({"contains":false,"minContains":0})", "[1]"));
  EXPECT_TRUE(Valid(R"({"minContains":5})", "[1]"));  // inert without contains
}

TEST(Schema, ObjectKeywords) {
  EXPECT_FALSE(Valid(R"({"required":["a"]})", "{}"));
  EXPECT_TRUE(Valid(R"({"required":["a"]})", "[]"));
  EXPECT_FALSE(Valid(R"({"dependentRequired":{"a":["b"]}})", R"({"a":1})"));
  EXPECT_TRUE(Valid(R"({"dependentRequired":{"a":["b"]}})", R"({"c":1})"));
  EXPECT_FALSE(Valid(R"({"properties":{"a":{"type":"string"}}})", R"({"a":1})"));
  EXPECT_FALSE(Valid(R"({"patternProperties":{"^x":{"type":"string"}}})", R"({"xa":1})"));
  EXPECT_FALSE(Valid(R"({"patternProperties":{"a":{"type":"string"},"b":{"minLength":3}}})", R"({"ab":"xy"})"));
  EXPECT_FALSE(Valid(R"({"properties":{"a":true},"additionalProperties":false})", R"({"a":1,"b":2})"));
  EXPECT_TRUE(Valid(R"({"properties":{"a":true},"patternProperties":{"^b":true},"additionalProperties":false})",
                    R"({"a":1,"bb":2})"));
  EXPECT_FALSE(Valid(R"({"propertyNames":{"maxLength":2}})", R"({"abc":1})"));
  EXPECT_FALSE(Valid(R"({"dependentSchemas":{"a":{"required":["b"]}}})", R"({"a":1})"));
  EXPECT_FALSE(Valid(R"({"maxProperties":1})", R"({"a":1,"b":2})"));
}

TEST(Schema, InPlaceApplicators) {
  EXPECT_TRUE(Valid(R"({"allOf":[{"type":"integer"},{"minimum":2}]})", "3"));
  EXPECT_FALSE(Valid(R"({"allOf":[{"type":"integer"},{"minimum":2}]})", "1"));
  EXPECT_TRUE(Valid(R"({"anyOf":[{"type":"string"},{"minimum":2}]})", "3"));
  EXPECT_FALSE(Valid(R"({"anyOf":[{"type":"string"},{"minimum":2}]})", "1"));
  EXPECT_FALSE(Valid(R"({"oneOf":[{"type":"integer"},{"minimum":2}]})", "3"));
  EXPECT_TRUE(Valid(R"({"oneOf":[{"type":"integer"},{"minimum":2}]})", "1"));
  EXPECT_FALSE(Valid(R"({"not":{"type":"integer"}})", "1"));
  const char* ite = R"({"if":{"type":"integer"},"then":{"minimum":0},"else":{"type":"string"}})";
  EXPECT_TRUE(Valid(ite, "5"));
  EXPECT_FALSE(Valid(ite, "-5"));
  EXPECT_TRUE(Valid(ite, "\"s\""));
  EXPECT_FALSE(Valid(ite, "null"));
  EXPECT_TRUE(Valid(R"({"then":false})", "1"));  // then without if is inert
}

TEST(Schema, UnevaluatedPropertiesSeesAnnotations) {
  const char* s = R"({"allOf":[{"properties":{"a":{"type":"integer"}}},{"properties":{"b":{"type":"integer"}}}],
                      "if":{"required":["a"]},"then":{"properties":{"c":{"type":"string"}}},
                      "unevaluatedProperties":false})";
  EXPECT_TRUE(Valid(s, R"({"a":1,"b":2})"));
  EXPECT_TRUE(Valid(s, R"({"a":1,"c":"yes"})"));
  EXPECT_FALSE(Valid(s, R"({"b":2,"c":"yes"})"));
  EXPECT_FALSE(Valid(s, R"({"a":1,"d":0})"));
}

TEST(Schema, UnevaluatedPropertiesIgnoresRejectedBranchesAndNot) {
  // `a` only counts when its branch accepted.
  EXPECT_FALSE(Valid(R"({"anyOf":[{"properties":{"a":true},"required":["z"]},{"required":["y"]}],
                         "unevaluatedProperties":false})", R"({"a":1,"y":2})"));
  EXPECT_FALSE(Valid(R"({"not":{"not":{"properties":{"a":true}}},"unevaluatedProperties":false})", R"({"a":1})"));
}

TEST(Schema, UnevaluatedItems) {
  EXPECT_TRUE(Valid(R"({"prefixItems":[true],"unevaluatedItems":false})", "[1]"));
  EXPECT_FALSE(Valid(R"({"prefixItems":[true],"unevaluatedItems":false})", "[1,2]"));
  EXPECT_TRUE(Valid(R"({"contains":{"type":"string"},"unevaluatedItems":false})", R"(["a","b"])"));
  EXPECT_FALSE(Valid(R"({"contains":{"type":"string"},"unevaluatedItems":false})", R"(["a",1])"));
  EXPECT_TRUE(Valid(R"({"allOf":[{"items":true}],"unevaluatedItems":false})", "[1,2,3]"));
}

TEST(Schema, RefAndDefs) {
  const char* s = R"({"$defs":{"pos":{"type":"integer","minimum":1}},"$ref":"#/$defs/pos"})";
  EXPECT_TRUE(Valid(s, "3"));
  EXPECT_FALSE(Valid(s, "0"));
  EXPECT_FALSE(Valid(R"({"$ref":"#/$defs/a%25b~1c","$defs":{"a%b/c":{"type":"string"}}})", "1"));
  // siblings of $ref are evaluated too
  EXPECT_FALSE(Valid(R"({"$ref":"#/$defs/x","maximum":1,"$defs":{"x":{"minimum":0}}})", "5"));
  // recursion
  const char* tree = R"({"type":"object","properties":{"child":{"$ref":"#"}},"required":["v"]})";
  EXPECT_TRUE(Valid(tree, R"({"v":1,"child":{"v":2}})"));
  EXPECT_FALSE(Valid(tree, R"({"v":1,"child":{}})"));
}

TEST(Schema, AnchorsAndIds) {
  EXPECT_TRUE(Valid(R"({"$ref":"#foo","$defs":{"a":{"$anchor":"foo","type":"integer"}}})", "1"));
  EXPECT_FALSE(Valid(R"({"$ref":"#foo","$defs":{"a":{"$anchor":"foo","type":"integer"}}})", "\"x\""));
  const char* s = R"({"$id":"http://example.com/root.json","$defs":{"A":{"$id":"a/b.json","type":"integer"}},
                      "$ref":"a/b.json"})";
  EXPECT_TRUE(Valid(s, "1"));
  EXPECT_FALSE(Valid(s, "\"x\""));
  // `$id` inside data is not an identifier
  EXPECT_TRUE(Valid(R"({"const":{"$id":"http://nowhere/","type":"string"}})", R"({"$id":"http://nowhere/","type":"string"})"));
}

TEST(Schema, RemotesAndRelativeResolution) {
  const char* s = R"({"$id":"http://localhost:1234/draft2020-12/root-of-its-own.json","type":"object",
      "properties":{"i":{"$ref":"integer.json"},"n":{"$ref":"subSchemas.json#/$defs/integer"}}})";
  std::vector<std::pair<std::string, std::string>> remotes = {
      {"http://localhost:1234/draft2020-12/integer.json", R"({"type":"integer"})"},
      {"http://localhost:1234/draft2020-12/subSchemas.json", R"({"$defs":{"integer":{"type":"integer"}}})"}};
  EXPECT_TRUE(ValidWithRemotes(s, remotes, R"({"i":1,"n":2})"));
  EXPECT_FALSE(ValidWithRemotes(s, remotes, R"({"i":"1"})"));
}

TEST(Schema, DynamicRefResolvesToOutermostAnchor) {
  const char* s = R"({
    "$id": "https://example.test/strings",
    "$defs": {
      "itemType": {"$dynamicAnchor": "itemType", "type": "string"},
      "list": {
        "$id": "https://example.test/list",
        "$defs": {"itemType": {"$dynamicAnchor": "itemType"}},
        "type": "array",
        "items": {"$dynamicRef": "#itemType"}
      }
    },
    "$ref": "https://example.test/list"})";
  EXPECT_TRUE(Valid(s, R"(["a","b"])"));
  EXPECT_FALSE(Valid(s, R"(["a",1])"));
}

TEST(Schema, DynamicRefWithoutDynamicAnchorActsLikeRef) {
  EXPECT_FALSE(Valid(R"({"$dynamicRef":"#/$defs/x","$defs":{"x":{"type":"string"}}})", "1"));
  EXPECT_TRUE(Valid(R"({"$dynamicRef":"#/$defs/x","$defs":{"x":{"type":"string"}}})", "\"s\""));
}

TEST(Schema, UnknownKeywordsAndFormatAreInert) {
  EXPECT_TRUE(Valid(R"({"type":"string","format":"ipv4"})", "\"nope\""));
  EXPECT_TRUE(Valid(R"({"definitions":{"x":false},"dependencies":{"a":false},"frobnicate":{"type":"string"}})", R"({"a":1})"));
  EXPECT_TRUE(Valid(R"({"$vocabulary":{"https://json-schema.org/draft/2020-12/vocab/validation":false},"minimum":5})", "6"));
  EXPECT_FALSE(Valid(R"({"$vocabulary":{"x":false},"minimum":5})", "4"));
}

TEST(Schema, UnresolvedReferenceThrowsOnlyWhenReached) {
  Schema s = Schema::compile_json(R"({"anyOf":[{"type":"string"},{"$ref":"http://nowhere.test/x"}]})");
  EXPECT_TRUE(s.is_valid(parse_json("\"ok\"")));
  EXPECT_THROW(s.is_valid(parse_json("1")), SchemaError);
}

TEST(Schema, InvalidPatternIsACompileError) {
  EXPECT_THROW(Schema::compile_json(R"({"pattern":"("})"), SchemaError);
}
