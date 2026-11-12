#include <gtest/gtest.h>

#include <cmath>

#include "svgraster/path.hpp"
#include "svgraster/shapes.hpp"

using namespace svgraster;

namespace {
std::vector<Polyline> flat(const std::string& d) { return flatten(parse_path_data(d), Matrix(), true); }
}  // namespace

TEST(PathData, LinesAndClose) {
    auto p = flat("M10 10 h10 v10 H10 z");
    ASSERT_EQ(p.size(), 1u);
    EXPECT_TRUE(p[0].closed);
    ASSERT_EQ(p[0].pts.size(), 4u);
    EXPECT_EQ(p[0].pts[1], (Point{20, 10}));
    EXPECT_EQ(p[0].pts[2], (Point{20, 20}));
    EXPECT_EQ(p[0].pts[3], (Point{10, 20}));
}

TEST(PathData, ImplicitLineToAfterMoveTo) {
    auto p = flat("m1 1 2 2 3 3");
    ASSERT_EQ(p.size(), 1u);
    ASSERT_EQ(p[0].pts.size(), 3u);
    EXPECT_EQ(p[0].pts[2], (Point{6, 6}));
}

TEST(PathData, StopsAtBadTokenKeepingEarlierCommands) {
    auto p = flat("M0 0 L10 0 L 5 x L 100 100");
    ASSERT_EQ(p.size(), 1u);
    EXPECT_EQ(p[0].pts.size(), 2u);
    p = flat("M0 0 L10 0 Z 5 5");
    ASSERT_EQ(p.size(), 1u);
    EXPECT_TRUE(p[0].closed);
}

TEST(PathData, LoneMoveToIsNotASubpath) {
    EXPECT_TRUE(flat("M5 5").empty());
    EXPECT_TRUE(flat("M5 5 M6 6 L7 7").size() == 1);
    EXPECT_EQ(flat("M5 5 Z").size(), 1u);
}

TEST(PathData, DrawingAfterCloseStartsNewSubpathAtStart) {
    auto p = flat("M10 10 L20 10 Z L30 30");
    ASSERT_EQ(p.size(), 2u);
    EXPECT_EQ(p[1].pts[0], (Point{10, 10}));
    EXPECT_FALSE(p[1].closed);
}

TEST(PathData, ArcFlagsNeedNoSeparators) {
    Path p = parse_path_data("M0 0a5 5 0 0110 0");
    ASSERT_FALSE(p.empty());
    EXPECT_NEAR(p.current().x, 10, 1e-12);
    EXPECT_NEAR(p.current().y, 0, 1e-12);
}

TEST(PathData, SmoothCubicReflects) {
    Path p = parse_path_data("M0 0 C0 10 10 10 10 0 S20 -10 20 0");
    const auto& s = p.segments();
    ASSERT_EQ(s.size(), 3u);
    EXPECT_EQ(s[2].p[0], (Point{10, -10}));
}

TEST(PathData, QuadraticBecomesCubic) {
    Path p = parse_path_data("M0 0 Q30 0 30 30");
    const auto& s = p.segments();
    ASSERT_EQ(s.size(), 2u);
    EXPECT_NEAR(s[1].p[0].x, 20, 1e-12);
    EXPECT_NEAR(s[1].p[1].y, 10, 1e-12);
}

TEST(Arc, QuarterCircleStaysOnCircle) {
    Path p;
    p.move_to({10, 0});
    p.arc_to(10, 10, 0, false, true, {0, 10});
    for (const Polyline& pl : flatten(p, Matrix(), true)) {
        for (Point q : pl.pts) EXPECT_NEAR(std::hypot(q.x, q.y), 10, 0.01);
    }
}

TEST(Arc, DegenerateCases) {
    Path p;
    p.move_to({1, 1});
    p.arc_to(5, 5, 0, false, true, {1, 1});
    EXPECT_EQ(p.segments().size(), 1u);  // dropped
    p.arc_to(0, 5, 0, false, true, {4, 4});
    EXPECT_EQ(p.segments().back().type, SegType::Line);
}

TEST(Arc, RadiiScaledUpWhenTooSmall) {
    Path p;
    p.move_to({0, 0});
    p.arc_to(1, 1, 0, false, true, {10, 0});
    EXPECT_NEAR(p.current().x, 10, 1e-12);
    auto polys = flatten(p, Matrix(), true);
    double max_y = 0;
    for (Point q : polys[0].pts) max_y = std::max(max_y, std::fabs(q.y));
    EXPECT_NEAR(max_y, 5, 0.02);  // semicircle of radius 5
}

TEST(Flatten, WithinToleranceOfCircle) {
    Path p = ellipse_path(0, 0, 100, 100);
    auto pts = flatten(p, Matrix(), true)[0].pts;
    for (Point q : pts) EXPECT_NEAR(std::hypot(q.x, q.y), 100, 0.05);
    // Chord midpoints must stay within 0.01 of the true circle as well.
    for (size_t i = 0; i < pts.size(); ++i) {
        Point m = (pts[i] + pts[(i + 1) % pts.size()]) * 0.5;
        EXPECT_GT(std::hypot(m.x, m.y), 100 - 0.011);
    }
}

TEST(Flatten, UserSpaceOutputUsesDeviceStepCount) {
    Path p = ellipse_path(0, 0, 1, 1);
    auto coarse = flatten(p, Matrix(), false)[0].pts.size();
    auto fine = flatten(p, Matrix::scale(100, 100), false)[0].pts.size();
    EXPECT_GT(fine, coarse);
    auto fine_pts = flatten(p, Matrix::scale(100, 100), false)[0].pts;
    for (Point q : fine_pts) EXPECT_NEAR(std::hypot(q.x, q.y), 1, 1e-3);
}

TEST(Shapes, RectRoundedCornersAreClamped) {
    Element el;
    el.tag = "rect";
    el.attrs = {{"width", "10"}, {"height", "20"}, {"rx", "100"}};
    auto p = shape_to_path(el);
    ASSERT_TRUE(p);
    auto polys = flatten(*p, Matrix(), true);
    ASSERT_EQ(polys.size(), 1u);
    // rx -> 5, ry -> 5 (takes rx's value, then clamped to height/2=10 -> stays 5)
    EXPECT_EQ(p->segments()[0].p[0], (Point{5, 0}));
}

TEST(Shapes, EmptyShapes) {
    Element el;
    el.tag = "rect";
    el.attrs = {{"width", "0"}, {"height", "5"}};
    EXPECT_FALSE(shape_to_path(el));
    Element c;
    c.tag = "circle";
    EXPECT_FALSE(shape_to_path(c));
    Element pl;
    pl.tag = "polyline";
    pl.attrs = {{"points", "1,2 3,4 5"}};
    auto p = shape_to_path(pl);
    ASSERT_TRUE(p);
    EXPECT_EQ(flatten(*p, Matrix(), true)[0].pts.size(), 2u);
}
