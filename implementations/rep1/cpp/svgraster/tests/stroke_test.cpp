#include <gtest/gtest.h>

#include <cmath>

#include "svgraster/raster.hpp"
#include "svgraster/stroke.hpp"

using namespace svgraster;

namespace {

// Area of the union of the stroke pieces, via the rasteriser.
double stroke_area(const std::vector<Polyline>& pl, const StrokeStyle& st, int size = 100) {
    Canvas cv(size, size);
    fill_polygons(cv, stroke_polygons(pl, st, Matrix()), FillRule::NonZero, 0, 0, 0, 1);
    double a = 0;
    for (int y = 0; y < size; ++y)
        for (int x = 0; x < size; ++x) a += cv.pixel(x, y)[3];
    return a;
}

Polyline line(Point a, Point b) { return {{a, b}, false}; }

}  // namespace

TEST(Stroke, ButtLineArea) {
    StrokeStyle st;
    st.width = 4;
    EXPECT_NEAR(stroke_area({line({10, 10}, {60, 10})}, st), 200, 0.01);
}

TEST(Stroke, SquareCapExtendsByHalfWidth) {
    StrokeStyle st;
    st.width = 4;
    st.cap = LineCap::Square;
    EXPECT_NEAR(stroke_area({line({10, 10}, {60, 10})}, st), 216, 0.01);
}

TEST(Stroke, RoundCapsAddADisc) {
    StrokeStyle st;
    st.width = 10;
    st.cap = LineCap::Round;
    EXPECT_NEAR(stroke_area({line({20, 50}, {70, 50})}, st), 500 + M_PI * 25, 0.5);
}

TEST(Stroke, SinglePointCaps) {
    StrokeStyle st;
    st.width = 10;
    Polyline pt{{{50, 50}, {50, 50}}, false};
    EXPECT_EQ(stroke_area({pt}, st), 0);
    st.cap = LineCap::Square;
    EXPECT_NEAR(stroke_area({pt}, st), 100, 1e-6);
    st.cap = LineCap::Round;
    EXPECT_NEAR(stroke_area({pt}, st), M_PI * 25, 0.5);
}

TEST(Stroke, MiterJoinFillsCorner) {
    StrokeStyle st;
    st.width = 10;
    st.join = LineJoin::Miter;
    Polyline corner{{{20, 80}, {20, 20}, {80, 20}}, false};
    // Two 60x10 bars overlap in a 5x5 square (the butt ends stop at the corner
    // point); the miter adds the missing outer 5x5 square.
    double miter = stroke_area({corner}, st);
    EXPECT_NEAR(miter, 2 * 600 - 25 + 25, 1e-6);
    st.join = LineJoin::Round;
    double round = stroke_area({corner}, st);
    st.join = LineJoin::Bevel;
    double bevel = stroke_area({corner}, st);
    EXPECT_GT(miter, round);
    EXPECT_GT(round, bevel);
}

TEST(Stroke, MiterLimitFallsBackToBevel) {
    StrokeStyle st;
    st.width = 10;
    st.miter_limit = 1.2;  // a right angle has ratio sqrt(2)
    Polyline corner{{{20, 80}, {20, 20}, {80, 20}}, false};
    double limited = stroke_area({corner}, st);
    st.join = LineJoin::Bevel;
    EXPECT_NEAR(limited, stroke_area({corner}, st), 1e-9);
}

TEST(Stroke, ClosedSquareHasNoCaps) {
    StrokeStyle st;
    st.width = 10;
    Polyline sq{{{20, 20}, {80, 20}, {80, 80}, {20, 80}}, true};
    // Outer 70x70 minus inner 50x50.
    EXPECT_NEAR(stroke_area({sq}, st), 70 * 70 - 50 * 50, 1e-6);
}

TEST(Stroke, ReversalWithRoundJoinMakesHalfDisc) {
    StrokeStyle st;
    st.width = 10;
    st.join = LineJoin::Round;
    Polyline back{{{20, 50}, {60, 50}, {20, 50}}, false};
    EXPECT_NEAR(stroke_area({back}, st), 40 * 10 + M_PI * 25 / 2, 0.5);
}

TEST(Stroke, PiecesAreOrientedPositively) {
    StrokeStyle st;
    st.width = 2;
    for (const Polygon& p : stroke_polygons({line({0, 0}, {10, 0})}, st, Matrix::scale(-1, 1))) {
        double a = 0;
        for (size_t i = 0; i < p.size(); ++i) a += cross(p[i], p[(i + 1) % p.size()]);
        EXPECT_GT(a, 0);
    }
}
