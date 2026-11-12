#include <gtest/gtest.h>

#include "svgraster/parse.hpp"

using namespace svgraster;

TEST(Number, Forms) {
    EXPECT_DOUBLE_EQ(*parse_number_prefix("5."), 5);
    EXPECT_DOUBLE_EQ(*parse_number_prefix(".5"), 0.5);
    EXPECT_DOUBLE_EQ(*parse_number_prefix(" -2.5e2x"), -250);
    EXPECT_FALSE(parse_number_prefix("e5"));
    EXPECT_FALSE(parse_number_prefix("."));
    size_t end = 0;
    EXPECT_DOUBLE_EQ(*parse_number_prefix("3e", &end), 3);
    EXPECT_EQ(end, 1u);
}

TEST(Number, List) {
    auto v = parse_number_list("1,2 3-4 .5.5 x 9");
    ASSERT_EQ(v.size(), 6u);  // stops at "x"
    EXPECT_DOUBLE_EQ(v[3], -4);
    EXPECT_DOUBLE_EQ(v[4], 0.5);
    EXPECT_DOUBLE_EQ(v[5], 0.5);
}

TEST(Length, PxAndDefault) {
    EXPECT_DOUBLE_EQ(*parse_length(" 12px "), 12);
    EXPECT_FALSE(parse_length("abc"));
}

TEST(Opacity, ParsingAndClamping) {
    EXPECT_DOUBLE_EQ(*parse_opacity("0.25"), 0.25);
    EXPECT_DOUBLE_EQ(*parse_opacity("50%"), 0.5);
    EXPECT_DOUBLE_EQ(*parse_opacity("1.5"), 1);
    EXPECT_DOUBLE_EQ(*parse_opacity("-1"), 0);
    EXPECT_FALSE(parse_opacity("bogus"));
    EXPECT_FALSE(parse_opacity("0.5x"));
}

TEST(Color, HexAndKeywords) {
    EXPECT_EQ(*parse_color("#f39"), (Rgb{255, 51, 153}));
    EXPECT_EQ(*parse_color("#1A2b3C"), (Rgb{0x1a, 0x2b, 0x3c}));
    EXPECT_EQ(*parse_color("CornflowerBlue"), (Rgb{100, 149, 237}));
    EXPECT_FALSE(parse_color("#12"));
    EXPECT_FALSE(parse_color("nonsense"));
}

TEST(Color, Rgb) {
    EXPECT_EQ(*parse_color("rgb(10, 20 ,30)"), (Rgb{10, 20, 30}));
    EXPECT_EQ(*parse_color("rgb(300 -5 127.5)"), (Rgb{255, 0, 128}));
    EXPECT_EQ(*parse_color("rgb(50%,100%,150%)"), (Rgb{128, 255, 255}));
}

TEST(Color, AllKeywordsPresent) {
    EXPECT_TRUE(named_color("aliceblue"));
    EXPECT_TRUE(named_color("yellowgreen"));
    EXPECT_EQ(*named_color("gray"), (Rgb{128, 128, 128}));
    EXPECT_EQ(*named_color("grey"), (Rgb{128, 128, 128}));
}

namespace {
void expect_matrix(const Matrix& m, double a, double b, double c, double d, double e, double f) {
    EXPECT_NEAR(m.a, a, 1e-12); EXPECT_NEAR(m.b, b, 1e-12); EXPECT_NEAR(m.c, c, 1e-12);
    EXPECT_NEAR(m.d, d, 1e-12); EXPECT_NEAR(m.e, e, 1e-12); EXPECT_NEAR(m.f, f, 1e-12);
}
}  // namespace

TEST(Transform, Basics) {
    expect_matrix(parse_transform("translate(5)"), 1, 0, 0, 1, 5, 0);
    expect_matrix(parse_transform("scale(2)"), 2, 0, 0, 2, 0, 0);
    expect_matrix(parse_transform("matrix(1 2 3 4 5 6)"), 1, 2, 3, 4, 5, 6);
    expect_matrix(parse_transform("rotate(90)"), 0, 1, -1, 0, 0, 0);
    expect_matrix(parse_transform("skewX(45)"), 1, 0, 1, 1, 0, 0);
}

TEST(Transform, CompositionAppliesRightmostFirst) {
    // translate(10,0) scale(2): scale first, then translate.
    Matrix m = parse_transform("translate(10,0) scale(2)");
    Point p = m.apply({1, 1});
    EXPECT_DOUBLE_EQ(p.x, 12);
    EXPECT_DOUBLE_EQ(p.y, 2);
}

TEST(Transform, RotateAboutPoint) {
    Point p = parse_transform("rotate(90 10 10)").apply({20, 10});
    EXPECT_NEAR(p.x, 10, 1e-12);
    EXPECT_NEAR(p.y, 20, 1e-12);
}

TEST(Transform, UnknownSkippedAndShortArgsSkipped) {
    expect_matrix(parse_transform("foo(1) translate(3,4) matrix(1 2)"), 1, 0, 0, 1, 3, 4);
}

TEST(Style, DeclarationsTrimmedAndFiltered) {
    auto m = parse_style("Fill : red ;; stroke:blue;bad; empty: ;");
    EXPECT_EQ(m.size(), 2u);
    EXPECT_EQ(m["fill"], "red");
    EXPECT_EQ(m["stroke"], "blue");
}
