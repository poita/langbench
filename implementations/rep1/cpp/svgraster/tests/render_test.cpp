#include <gtest/gtest.h>

#include "svgraster/svgraster.hpp"

using namespace svgraster;

namespace {

struct Px { int r, g, b; };

Px px(const std::vector<uint8_t>& rgb, int w, int x, int y) {
    size_t i = (static_cast<size_t>(y) * w + x) * 3;
    return {rgb[i], rgb[i + 1], rgb[i + 2]};
}

std::vector<uint8_t> render(const std::string& svg, int w, int h) { return render_svg(svg, w, h).to_rgb8(); }

void expect_px(Px p, int r, int g, int b, int tol = 0) {
    EXPECT_NEAR(p.r, r, tol);
    EXPECT_NEAR(p.g, g, tol);
    EXPECT_NEAR(p.b, b, tol);
}

}  // namespace

TEST(Render, SpecExampleFractionalRect) {
    auto img = render(
        "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 8 4' width='8' height='4'>"
        "<rect x='1' y='1' width='3.5' height='2' fill='#0000ff'/></svg>",
        8, 4);
    expect_px(px(img, 8, 0, 1), 255, 255, 255);
    expect_px(px(img, 8, 1, 1), 0, 0, 255);
    expect_px(px(img, 8, 4, 1), 128, 128, 255);
    expect_px(px(img, 8, 5, 1), 255, 255, 255);
    expect_px(px(img, 8, 2, 0), 255, 255, 255);
}

TEST(Render, SpecExampleStrokeUnderScaling) {
    auto img = render(
        "<svg viewBox='0 0 10 10'><g transform='scale(2)'>"
        "<rect x='1' y='1' width='3' height='3' fill='none' stroke='black'/></g></svg>",
        40, 40);
    expect_px(px(img, 40, 4, 20), 0, 0, 0);
    expect_px(px(img, 40, 11, 20), 0, 0, 0);
    expect_px(px(img, 40, 12, 20), 255, 255, 255);
    expect_px(px(img, 40, 3, 20), 255, 255, 255);
}

TEST(Render, GroupOpacityUsesOffscreenLayer) {
    auto img = render(
        "<svg width='10' height='10'><g opacity='0.5'>"
        "<rect width='10' height='10' fill='red'/><rect width='10' height='10' fill='blue'/></g></svg>",
        10, 10);
    expect_px(px(img, 10, 5, 5), 128, 128, 255);
}

TEST(Render, PerShapeOpacityBlendsTwice) {
    auto img = render(
        "<svg width='10' height='10'>"
        "<rect width='10' height='10' fill='red' opacity='0.5'/>"
        "<rect width='10' height='10' fill='blue' opacity='0.5'/></svg>",
        10, 10);
    expect_px(px(img, 10, 5, 5), 128, 64, 191, 1);
}

TEST(Render, EvenOddStarCentreIsEmpty) {
    const char* tmpl =
        "<svg width='20' height='20'><path fill='black' fill-rule='%s' d='M10 0 L16 18 L0 7 L20 7 L4 18 Z'/></svg>";
    char buf[256];
    snprintf(buf, sizeof buf, tmpl, "evenodd");
    expect_px(px(render(buf, 20, 20), 20, 10, 10), 255, 255, 255);
    snprintf(buf, sizeof buf, tmpl, "nonzero");
    expect_px(px(render(buf, 20, 20), 20, 10, 10), 0, 0, 0);
    snprintf(buf, sizeof buf, tmpl, "EVENODD");  // case-sensitive: falls back to nonzero
    expect_px(px(render(buf, 20, 20), 20, 10, 10), 0, 0, 0);
}

TEST(Render, UseInheritsAndTranslates) {
    auto img = render(
        "<svg width='20' height='10'><defs><rect id='r' width='5' height='5' stroke='none'/></defs>"
        "<use xlink:href='#r' x='10' y='2' fill='lime'/></svg>",
        20, 10);
    expect_px(px(img, 20, 12, 3), 0, 255, 0);
    expect_px(px(img, 20, 2, 3), 255, 255, 255);
}

TEST(Render, DisplayAttributeVersusStyle) {
    auto img = render(
        "<svg width='3' height='1'>"
        "<rect width='1' height='1' display='none'/>"
        "<rect x='1' width='1' height='1' display='none' style='display:inline'/>"
        "<g display='none'><g display='inline'><rect x='2' width='1' height='1'/></g></g></svg>",
        3, 1);
    expect_px(px(img, 3, 0, 0), 255, 255, 255);
    expect_px(px(img, 3, 1, 0), 0, 0, 0);
    expect_px(px(img, 3, 2, 0), 255, 255, 255);
}

TEST(Render, CurrentColorAndStyleInheritance) {
    auto img = render(
        "<svg width='2' height='1' color='red'>"
        "<rect width='1' height='1' fill='currentColor'/>"
        "<rect x='1' width='1' height='1' style='fill:#00f' fill='#0f0'/></svg>",
        2, 1);
    expect_px(px(img, 2, 0, 0), 255, 0, 0);
    expect_px(px(img, 2, 1, 0), 0, 0, 255);
}

TEST(Render, ViewBoxStretches) {
    auto img = render("<svg viewBox='0 0 2 1'><rect width='1' height='1'/></svg>", 8, 8);
    expect_px(px(img, 8, 3, 7), 0, 0, 0);
    expect_px(px(img, 8, 4, 0), 255, 255, 255);
}

TEST(Render, NonSvgRootGivesBlankImage) {
    auto img = render("<html/>", 2, 2);
    expect_px(px(img, 2, 1, 1), 255, 255, 255);
}

TEST(Render, EndToEndPpm) {
    std::string ppm = render_svg_to_ppm("<svg/>", 3, 2);
    EXPECT_EQ(ppm.substr(0, 11), "P6\n3 2\n255\n");
    EXPECT_EQ(ppm.size(), 11u + 18);
}
