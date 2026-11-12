from svgraster import render_svg, render_to_ppm

from helpers import pixel, render


def test_spec_example_fractional_rect():
    rgb = render('<rect x="1" y="1" width="3.5" height="2" fill="#0000ff"/>', 8, 4)
    row = [pixel(rgb, 8, x, 1) for x in range(8)]
    white, blue = (255, 255, 255), (0, 0, 255)
    assert row == [white, blue, blue, blue, (128, 128, 255), white, white, white]
    assert all(pixel(rgb, 8, x, 0) == white for x in range(8))


def test_ppm_header_and_size():
    ppm = render_to_ppm("<svg/>", 3, 2)
    assert ppm.startswith(b"P6\n3 2\n255\n") and len(ppm) == 11 + 18
    assert set(ppm[11:]) == {255}


def test_stroke_frame_with_scaling():
    body = ('<g transform="scale(2)"><rect x="1" y="1" width="3" height="3" fill="none" '
            'stroke="black" stroke-width="1"/></g>')
    rgb = render(body, 40, 40, vb="0 0 10 10")
    assert pixel(rgb, 40, 3, 20) == (255, 255, 255)
    assert pixel(rgb, 40, 4, 20) == (0, 0, 0)
    assert pixel(rgb, 40, 11, 20) == (0, 0, 0)
    assert pixel(rgb, 40, 12, 20) == (255, 255, 255)
    assert pixel(rgb, 40, 20, 20) == (255, 255, 255)


def test_group_opacity_vs_element_opacity():
    circles = ('<circle cx="20" cy="20" r="15" fill="red"%s/>'
               '<circle cx="30" cy="20" r="15" fill="blue"%s/>')
    grouped = render('<g opacity="0.5">' + circles % ("", "") + "</g>", 50, 40)
    separate = render(circles % (' opacity="0.5"', ' opacity="0.5"'), 50, 40)
    assert pixel(grouped, 50, 25, 20) == (128, 128, 255)
    assert pixel(separate, 50, 25, 20) != pixel(grouped, 50, 25, 20)


def test_fill_rule():
    star = '<path d="M10 0 L16 18 L0 7 L20 7 L4 18 Z" fill="black" fill-rule="%s"/>'
    nz = render(star % "nonzero", 20, 20)
    eo = render(star % "evenodd", 20, 20)
    assert pixel(nz, 20, 10, 9) == (0, 0, 0)
    assert pixel(eo, 20, 10, 9) == (255, 255, 255)


def test_display_precedence_and_inheritance():
    body = ('<rect width="4" height="4" display="none" style="display:inline" fill="red"/>'
            '<g display="none"><rect x="4" width="4" height="4" style="display:inline"/></g>'
            '<g fill="lime" stroke="none"><rect y="4" width="4" height="4" style="fill:"/></g>')
    rgb = render(body, 8, 8)
    assert pixel(rgb, 8, 1, 1) == (255, 0, 0)
    assert pixel(rgb, 8, 5, 1) == (255, 255, 255)
    assert pixel(rgb, 8, 1, 5) == (0, 255, 0)


def test_use_translates_and_inherits():
    body = ('<defs><rect id="r" width="2" height="2"/></defs>'
            '<g fill="blue"><use href="#r" x="3" y="1"/></g><use href="#missing"/>')
    rgb = render(body, 8, 4)
    assert pixel(rgb, 8, 3, 1) == (0, 0, 255)
    assert pixel(rgb, 8, 0, 0) == (255, 255, 255)
    assert pixel(rgb, 8, 4, 2) == (0, 0, 255)


def test_unrendered_elements_and_currentcolor():
    body = ('<defs><rect width="8" height="8"/></defs><text><rect width="8" height="8"/></text>'
            '<rect width="2" height="2" fill="currentColor" color="red"/>')
    rgb = render(body, 8, 8)
    assert pixel(rgb, 8, 5, 5) == (255, 255, 255)
    assert pixel(rgb, 8, 0, 0) == (255, 0, 0)


def test_viewbox_stretch_and_fallback_to_size():
    rgb = render('<rect width="1" height="1"/>', 8, 4, vb="0 0 2 2")
    assert pixel(rgb, 8, 3, 1) == (0, 0, 0) and pixel(rgb, 8, 4, 1) == (255, 255, 255)
    svg = '<svg width="2" height="2"><rect width="1" height="1"/></svg>'
    out = render_svg(svg, 4, 4)
    assert pixel(out, 4, 1, 1) == (0, 0, 0) and pixel(out, 4, 2, 2) == (255, 255, 255)


def test_round_cap_on_point():
    body = '<path d="M4 4 L4 4" stroke="black" stroke-width="4" stroke-linecap="round"/>'
    rgb = render(body, 8, 8)
    assert pixel(rgb, 8, 4, 4) == (0, 0, 0) and pixel(rgb, 8, 0, 0) == (255, 255, 255)
