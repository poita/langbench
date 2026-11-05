module test_render;

import std.conv : to;
import std.math : abs;
import svgraster.batch;
import svgraster.render;
import svgraster.xml;

private struct Px { int r, g, b; }

private Px at(const Image im, int x, int y)
{
    auto i = (y * im.width + x) * 3;
    return Px(im.rgb[i], im.rgb[i + 1], im.rgb[i + 2]);
}

private bool near(Px a, Px b, int tol = 1)
{
    return abs(a.r - b.r) <= tol && abs(a.g - b.g) <= tol && abs(a.b - b.b) <= tol;
}

private enum white = Px(255, 255, 255);

unittest // spec example 10.1: rectangle with a fractional edge
{
    auto im = renderSvg(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 4" width="8" height="4">
        <rect x="1" y="1" width="3.5" height="2" fill="#0000ff"/></svg>`, 8, 4);
    assert(at(im, 0, 1) == white);
    assert(at(im, 1, 1) == Px(0, 0, 255));
    assert(at(im, 3, 1) == Px(0, 0, 255));
    assert(at(im, 4, 1) == Px(0x80, 0x80, 255));
    assert(at(im, 5, 1) == white);
    assert(at(im, 2, 0) == white && at(im, 2, 3) == white);
}

unittest // spec example 10.2: transforms scale the stroke; crisp edges
{
    auto im = renderSvg(`<svg viewBox="0 0 10 10" width="10" height="10"><g transform="scale(2)">
        <rect x="1" y="1" width="3" height="3" fill="none" stroke="black" stroke-width="1"/></g></svg>`, 40, 40);
    assert(at(im, 3, 20) == white);
    assert(at(im, 4, 20) == Px(0, 0, 0));
    assert(at(im, 11, 20) == Px(0, 0, 0));
    assert(at(im, 12, 20) == white);
    assert(at(im, 27, 20) == white);
    assert(at(im, 28, 20) == Px(0, 0, 0));
    assert(at(im, 35, 20) == Px(0, 0, 0));
    assert(at(im, 36, 20) == white);
}

unittest // group opacity composes the group first
{
    enum svg = `<svg viewBox="0 0 10 10">%s</svg>`;
    auto group = renderSvg(`<svg viewBox="0 0 10 10"><g opacity="0.5">
        <rect width="10" height="10" fill="red"/><rect width="10" height="10" fill="blue"/></g></svg>`, 10, 10);
    assert(near(at(group, 5, 5), Px(128, 128, 255)));
    auto each = renderSvg(`<svg viewBox="0 0 10 10">
        <rect width="10" height="10" fill="red" opacity="0.5"/><rect width="10" height="10" fill="blue" opacity="0.5"/></svg>`, 10, 10);
    assert(near(at(each, 5, 5), Px(128, 64, 191)));
    // opacity 0 renders nothing, and a shape's fill and stroke fade as one
    auto z = renderSvg(`<svg viewBox="0 0 10 10"><rect width="10" height="10" opacity="0"/></svg>`, 10, 10);
    assert(at(z, 5, 5) == white);
    auto one = renderSvg(`<svg viewBox="0 0 10 10"><rect x="2" y="2" width="6" height="6" fill="blue"
        stroke="blue" stroke-width="2" opacity=".5"/></svg>`, 10, 10);
    assert(near(at(one, 2, 5), Px(128, 128, 255))); // fill/stroke overlap is not doubled
}

unittest // inheritance, style precedence, currentColor, display
{
    auto im = renderSvg(`<svg viewBox="0 0 40 10">
        <g fill="#00ff00" color="#ff0000">
          <rect x="0" width="10" height="10"/>
          <rect x="10" width="10" height="10" style="fill:currentColor" fill="blue"/>
          <rect x="20" width="10" height="10" fill="blue" display="none" style="display:inline"/>
          <rect x="30" width="10" height="10" fill="EVENODD" display="none"/>
        </g></svg>`, 40, 10);
    assert(at(im, 5, 5) == Px(0, 255, 0));
    assert(at(im, 15, 5) == Px(255, 0, 0));
    assert(at(im, 25, 5) == Px(0, 0, 255));
    assert(at(im, 35, 5) == white);
}

unittest // use: lookup by id, translate, inherited properties, defs not drawn
{
    auto im = renderSvg(`<svg xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 30 10">
        <defs><rect id="r" width="10" height="10"/><g id="g" fill="red"><rect width="10" height="10"/></g></defs>
        <use xlink:href="#r" x="10" fill="blue"/>
        <use href="#g" x="20" fill="blue"/>
        <use href="#nothing"/></svg>`, 30, 10);
    assert(at(im, 5, 5) == white);
    assert(at(im, 15, 5) == Px(0, 0, 255));
    assert(at(im, 25, 5) == Px(255, 0, 0)); // the referenced element's own fill wins
}

unittest // viewport selection and stretching
{
    auto im = renderSvg(`<svg width="10" height="10"><rect width="5" height="10"/></svg>`, 20, 10);
    assert(at(im, 9, 5) == Px(0, 0, 0) && at(im, 10, 5) == white);
    im = renderSvg(`<svg><rect width="5" height="10"/></svg>`, 10, 10);
    assert(at(im, 4, 5) == Px(0, 0, 0) && at(im, 5, 5) == white);
    im = renderSvg(`<svg viewBox="10 10 10 10"><rect x="10" y="10" width="5" height="10"/></svg>`, 10, 10);
    assert(at(im, 4, 5) == Px(0, 0, 0) && at(im, 5, 5) == white);
}

unittest // PPM encoding
{
    auto im = renderSvg(`<svg/>`, 2, 1);
    auto ppm = im.toPpm();
    assert(cast(string) ppm[0 .. 11] == "P6\n2 1\n255\n");
    assert(ppm.length == 11 + 6);
    foreach (b; ppm[11 .. $])
        assert(b == 255);
}

unittest // render.txt parsing
{
    auto jobs = parseJobs("# comment\r\n\n   \nlogo.svg 64 32\r\n  a.svg\t10   20  \nbad.svg 0 5\nshort.svg 5\n");
    assert(jobs.length == 2);
    assert(jobs[0] == Job("logo.svg", 64, 32));
    assert(jobs[1] == Job("a.svg", 10, 20));
    assert(jobs[0].outputName == "logo.ppm");
}
