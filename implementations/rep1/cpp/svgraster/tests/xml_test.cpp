#include <gtest/gtest.h>

#include "svgraster/xml.hpp"

using namespace svgraster;

TEST(Xml, ParsesNestedElementsAndAttributes) {
    auto root = parse_xml("<svg a='1' b = \"2\"><g><rect x=\"3\"/></g><circle/></svg>");
    ASSERT_TRUE(root);
    EXPECT_EQ(root->tag, "svg");
    EXPECT_EQ(*root->attr("a"), "1");
    EXPECT_EQ(*root->attr("b"), "2");
    ASSERT_EQ(root->children.size(), 2u);
    EXPECT_EQ(root->children[0]->tag, "g");
    EXPECT_EQ(*root->children[0]->children[0]->attr("x"), "3");
    EXPECT_EQ(root->children[1]->tag, "circle");
}

TEST(Xml, SkipsProlog) {
    auto root = parse_xml(
        "<?xml version=\"1.0\"?><!DOCTYPE svg [ <!ENTITY a \"<b>\"> ]><!-- <c> -->"
        "<svg><![CDATA[ <x> ]]><g/></svg>");
    ASSERT_TRUE(root);
    EXPECT_EQ(root->tag, "svg");
    ASSERT_EQ(root->children.size(), 1u);
}

TEST(Xml, GreaterThanInsideQuotedValue) {
    auto root = parse_xml("<svg><path d=\"a>b\" fill='x'/></svg>");
    ASSERT_TRUE(root);
    EXPECT_EQ(*root->children[0]->attr("d"), "a>b");
    EXPECT_EQ(*root->children[0]->attr("fill"), "x");
}

TEST(Xml, StripsNamespacePrefixesAndDropsXmlns) {
    auto root = parse_xml("<svg:svg xmlns:svg='u' xmlns='v'><use xlink:href='#a'/></svg:svg>");
    ASSERT_TRUE(root);
    EXPECT_EQ(root->tag, "svg");
    EXPECT_TRUE(root->attrs.empty());
    EXPECT_EQ(*root->children[0]->attr("href"), "#a");
}

TEST(Xml, LastDuplicateAttributeWins) {
    auto root = parse_xml("<svg a='1' a='2'/>");
    EXPECT_EQ(*root->attr("a"), "2");
}

TEST(Xml, DecodesEntities) {
    EXPECT_EQ(decode_entities("a&amp;b&lt;&gt;&quot;&apos;"), "a&b<>\"'");
    EXPECT_EQ(decode_entities("&#65;&#x42;"), "AB");
    EXPECT_EQ(decode_entities("&nbsp; & &#;"), "&nbsp; & &#;");
}

TEST(Xml, NoElement) { EXPECT_FALSE(parse_xml("just text")); }
