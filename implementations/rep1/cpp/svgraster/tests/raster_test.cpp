#include <gtest/gtest.h>

#include "svgraster/raster.hpp"

using namespace svgraster;

namespace {
Polygon rect(double x0, double y0, double x1, double y1) { return {{x0, y0}, {x1, y0}, {x1, y1}, {x0, y1}}; }
}  // namespace

TEST(Raster, FractionalRectCoverage) {
    Canvas cv(8, 4);
    fill_polygons(cv, {rect(1, 1, 4.5, 3)}, FillRule::NonZero, 0, 0, 1, 1);
    EXPECT_DOUBLE_EQ(cv.pixel(0, 1)[3], 0);
    EXPECT_DOUBLE_EQ(cv.pixel(1, 1)[3], 1);
    EXPECT_DOUBLE_EQ(cv.pixel(4, 1)[3], 0.5);
    EXPECT_DOUBLE_EQ(cv.pixel(5, 1)[3], 0);
    EXPECT_DOUBLE_EQ(cv.pixel(2, 0)[3], 0);
}

TEST(Raster, FractionalRowCoverage) {
    Canvas cv(4, 4);
    fill_polygons(cv, {rect(0, 0.25, 4, 1.75)}, FillRule::NonZero, 1, 1, 1, 1);
    EXPECT_NEAR(cv.pixel(0, 0)[3], 0.75, 1e-12);
    EXPECT_NEAR(cv.pixel(0, 1)[3], 0.75, 1e-12);
}

TEST(Raster, EvenOddLeavesHole) {
    Canvas a(10, 10), b(10, 10);
    std::vector<Polygon> polys{rect(0, 0, 10, 10), rect(3, 3, 7, 7)};
    fill_polygons(a, polys, FillRule::EvenOdd, 0, 0, 0, 1);
    fill_polygons(b, polys, FillRule::NonZero, 0, 0, 0, 1);
    EXPECT_DOUBLE_EQ(a.pixel(5, 5)[3], 0);
    EXPECT_DOUBLE_EQ(b.pixel(5, 5)[3], 1);
    EXPECT_DOUBLE_EQ(a.pixel(1, 1)[3], 1);
}

TEST(Raster, OppositeWindingCancelsUnderNonZero) {
    Canvas cv(10, 10);
    Polygon inner = rect(3, 3, 7, 7);
    std::reverse(inner.begin(), inner.end());
    fill_polygons(cv, {rect(0, 0, 10, 10), inner}, FillRule::NonZero, 0, 0, 0, 1);
    EXPECT_DOUBLE_EQ(cv.pixel(5, 5)[3], 0);
}

TEST(Raster, ClipsToCanvas) {
    Canvas cv(4, 4);
    fill_polygons(cv, {rect(-100, -100, 100, 100)}, FillRule::NonZero, 1, 0, 0, 1);
    EXPECT_DOUBLE_EQ(cv.pixel(3, 3)[0], 1);
    fill_polygons(cv, {rect(10, 10, 20, 20)}, FillRule::NonZero, 0, 0, 0, 1);
}

TEST(Raster, SourceOverWithOpacity) {
    Canvas cv(1, 1);
    fill_polygons(cv, {rect(0, 0, 1, 1)}, FillRule::NonZero, 1, 0, 0, 0.5);
    fill_polygons(cv, {rect(0, 0, 1, 1)}, FillRule::NonZero, 0, 0, 1, 0.5);
    const double* p = cv.pixel(0, 0);
    EXPECT_DOUBLE_EQ(p[0], 0.25);
    EXPECT_DOUBLE_EQ(p[2], 0.5);
    EXPECT_DOUBLE_EQ(p[3], 0.75);
}

TEST(Raster, LayerComposite) {
    Canvas dst(1, 1), layer(1, 1);
    fill_polygons(layer, {rect(0, 0, 1, 1)}, FillRule::NonZero, 0, 0, 0, 1);
    dst.composite_layer(layer, 0.5);
    EXPECT_DOUBLE_EQ(dst.pixel(0, 0)[3], 0.5);
    auto rgb = dst.to_rgb8();
    EXPECT_EQ(rgb[0], 128);
}

TEST(Raster, PpmEncoding) {
    Canvas cv(2, 1);
    std::string ppm = encode_ppm(cv);
    EXPECT_EQ(ppm.substr(0, 11), "P6\n2 1\n255\n");
    EXPECT_EQ(ppm.size(), 11u + 6);
    EXPECT_EQ(static_cast<unsigned char>(ppm.back()), 255);
}
