//! End-to-end tests: render small documents and inspect the output pixels.

use svgraster::jobs::{parse_render_list, render_directory};
use svgraster::render_svg;

/// Renders `svg` and returns a closure-free pixel accessor over the PPM bytes.
struct Image {
    w: usize,
    data: Vec<u8>,
}

impl Image {
    fn px(&self, x: usize, y: usize) -> [u8; 3] {
        let i = (y * self.w + x) * 3;
        [self.data[i], self.data[i + 1], self.data[i + 2]]
    }
}

fn render(svg: &str, w: usize, h: usize) -> Image {
    let ppm = render_svg(svg, w, h).unwrap().to_ppm();
    let header = format!("P6\n{w} {h}\n255\n").into_bytes();
    assert!(ppm.starts_with(&header));
    assert_eq!(ppm.len(), header.len() + w * h * 3);
    Image { w, data: ppm[header.len()..].to_vec() }
}

const WHITE: [u8; 3] = [255, 255, 255];

#[test]
fn fractional_rectangle_edge() {
    let img = render(
        r##"<svg viewBox="0 0 8 4" width="8" height="4"><rect x="1" y="1" width="3.5" height="2" fill="#0000ff"/></svg>"##,
        8,
        4,
    );
    assert_eq!(img.px(0, 1), WHITE);
    assert_eq!(img.px(1, 1), [0, 0, 255]);
    assert_eq!(img.px(3, 1), [0, 0, 255]);
    assert_eq!(img.px(4, 1), [128, 128, 255]);
    assert_eq!(img.px(5, 1), WHITE);
    assert_eq!(img.px(2, 0), WHITE);
    assert_eq!(img.px(2, 3), WHITE);
}

#[test]
fn stroke_is_outlined_in_user_space() {
    let img = render(
        r##"<svg viewBox="0 0 10 10" width="10" height="10"><g transform="scale(2)">
           <rect x="1" y="1" width="3" height="3" fill="none" stroke="black" stroke-width="1"/></g></svg>"##,
        40,
        40,
    );
    assert_eq!(img.px(4, 20), [0, 0, 0]);
    assert_eq!(img.px(11, 20), [0, 0, 0]);
    assert_eq!(img.px(12, 20), WHITE);
    assert_eq!(img.px(3, 20), WHITE);
    assert_eq!(img.px(20, 20), WHITE);
    assert_eq!(img.px(35, 20), [0, 0, 0]);
    assert_eq!(img.px(36, 20), WHITE);
}

#[test]
fn evenodd_star_has_hole() {
    let svg = |rule: &str| {
        format!(
            r##"<svg viewBox="0 0 20 20"><path fill="#8e44ad" fill-rule="{rule}" d="M10 0 L16 18 L0 7 L20 7 L4 18 Z"/></svg>"##
        )
    };
    assert_eq!(render(&svg("evenodd"), 20, 20).px(10, 10), WHITE);
    assert_eq!(render(&svg("nonzero"), 20, 20).px(10, 10), [0x8e, 0x44, 0xad]);
    // Case-sensitive keyword: EVENODD is invalid, so the initial value applies.
    assert_eq!(render(&svg("EVENODD"), 20, 20).px(10, 10), [0x8e, 0x44, 0xad]);
}

#[test]
fn group_opacity_composites_as_one_object() {
    let img = render(
        r##"<svg viewBox="0 0 50 40"><g opacity="0.5">
           <circle cx="20" cy="20" r="15" fill="red"/><circle cx="30" cy="20" r="15" fill="blue"/></g></svg>"##,
        50,
        40,
    );
    // Overlap shows only blue over white at 50%.
    assert_eq!(img.px(25, 20), [128, 128, 255]);
    // Red only region.
    assert_eq!(img.px(10, 20), [255, 128, 128]);
}

#[test]
fn per_shape_opacity_differs_from_group_opacity() {
    let img = render(
        r##"<svg viewBox="0 0 50 40">
           <circle cx="20" cy="20" r="15" fill="red" opacity="0.5"/>
           <circle cx="30" cy="20" r="15" fill="blue" opacity="0.5"/></svg>"##,
        50,
        40,
    );
    let p = img.px(25, 20);
    assert!(p[0] > 100 && p[0] < 150, "{p:?}");
}

#[test]
fn use_inherits_and_translates() {
    let img = render(
        r##"<svg viewBox="0 0 20 10"><defs><rect id="r" width="5" height="5" fill="lime"/></defs>
           <g fill="red"><use href="#r" x="10" y="2"/><use href="#missing"/></g></svg>"##,
        20,
        10,
    );
    // The referenced element's own fill wins over the inherited one.
    assert_eq!(img.px(12, 4), [0, 255, 0]);
    assert_eq!(img.px(2, 2), WHITE);
}

#[test]
fn display_none_and_style_precedence() {
    let img = render(
        r##"<svg viewBox="0 0 12 4">
           <rect width="4" height="4" display="none"/>
           <rect x="4" width="4" height="4" display="none" style="display:inline" fill="blue"/>
           <rect x="8" width="4" height="4" fill="red" style="fill:lime"/></svg>"##,
        12,
        4,
    );
    assert_eq!(img.px(1, 1), WHITE);
    assert_eq!(img.px(5, 1), [0, 0, 255]);
    assert_eq!(img.px(9, 1), [0, 255, 0]);
}

#[test]
fn non_rendered_elements_are_skipped() {
    let img = render(
        r##"<svg viewBox="0 0 4 4"><defs><rect width="4" height="4"/></defs><symbol><rect width="4" height="4"/></symbol>
           <text><rect width="4" height="4"/></text></svg>"##,
        4,
        4,
    );
    assert_eq!(img.px(1, 1), WHITE);
}

#[test]
fn viewbox_is_stretched() {
    let img = render(r##"<svg viewBox="0 0 2 1"><rect width="1" height="1" fill="black"/></svg>"##, 20, 20);
    assert_eq!(img.px(9, 10), [0, 0, 0]);
    assert_eq!(img.px(10, 10), WHITE);
}

#[test]
fn round_cap_on_single_point_subpath() {
    let img = render(
        r##"<svg viewBox="0 0 10 10"><path d="M5 5 L5 5" stroke="black" stroke-width="6" stroke-linecap="round"/></svg>"##,
        10,
        10,
    );
    assert_eq!(img.px(5, 5), [0, 0, 0]);
    assert_eq!(img.px(0, 0), WHITE);
}

#[test]
fn current_color_and_colour_forms() {
    let img = render(
        r##"<svg viewBox="0 0 12 4"><g color="#ff7f00"><rect width="4" height="4" fill="currentColor"/></g>
           <rect x="4" width="4" height="4" fill="rgb(20%, 45%, 90%)"/><rect x="8" width="4" height="4" fill="#f39"/></svg>"##,
        12,
        4,
    );
    assert_eq!(img.px(1, 1), [255, 127, 0]);
    assert_eq!(img.px(5, 1), [51, 115, 230]);
    assert_eq!(img.px(9, 1), [255, 51, 153]);
}

#[test]
fn non_svg_root_is_an_error() {
    assert!(render_svg("<html/>", 4, 4).is_err());
}

#[test]
fn directory_driver_writes_one_ppm_per_line() {
    let base = std::env::temp_dir().join(format!("svgraster-test-{}", std::process::id()));
    let (inp, out) = (base.join("in"), base.join("out"));
    std::fs::create_dir_all(&inp).unwrap();
    std::fs::write(inp.join("render.txt"), "# comment\na.svg 4 2\n\nb.svg 3 3\n").unwrap();
    std::fs::write(inp.join("a.svg"), r##"<svg viewBox="0 0 4 2"><rect width="4" height="2"/></svg>"##).unwrap();
    std::fs::write(inp.join("b.svg"), r##"<svg width="3" height="3"/>"##).unwrap();
    let failures = render_directory(&inp, &out).unwrap();
    assert!(failures.is_empty());
    let a = std::fs::read(out.join("a.ppm")).unwrap();
    assert_eq!(&a[..], &[&b"P6\n4 2\n255\n"[..], &[0u8; 24]].concat()[..]);
    let b = std::fs::read(out.join("b.ppm")).unwrap();
    assert_eq!(b.len(), 11 + 27);
    std::fs::remove_dir_all(&base).unwrap();
    assert_eq!(parse_render_list("x.svg 1 1").unwrap().len(), 1);
}
