//! Colours: the SVG 1.1 keyword table and colour/paint value parsing.

use crate::number::{parse_number, trim_ws};

/// An 8-bit sRGB colour.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rgb(pub u8, pub u8, pub u8);

impl Rgb {
    /// Black.
    pub const BLACK: Rgb = Rgb(0, 0, 0);

    /// The channels as values in `[0, 1]`.
    pub fn to_unit(self) -> [f64; 3] {
        [self.0 as f64 / 255.0, self.1 as f64 / 255.0, self.2 as f64 / 255.0]
    }
}

/// A parsed `fill` or `stroke` value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Paint {
    /// `none`.
    None,
    /// `currentColor`, resolved against the `color` property when painting.
    CurrentColor,
    /// A concrete colour.
    Color(Rgb),
}

/// Parses a paint value (`none`, `currentColor` or a colour).
pub fn parse_paint(s: &str) -> Option<Paint> {
    let s = trim_ws(s);
    if s.eq_ignore_ascii_case("none") {
        Some(Paint::None)
    } else if s.eq_ignore_ascii_case("currentcolor") {
        Some(Paint::CurrentColor)
    } else {
        parse_color(s).map(Paint::Color)
    }
}

/// Parses a colour: `#rgb`, `#rrggbb`, `rgb(...)` or a keyword.
pub fn parse_color(s: &str) -> Option<Rgb> {
    let s = trim_ws(s);
    if let Some(hex) = s.strip_prefix('#') {
        return parse_hex(hex);
    }
    if s.len() >= 4 && s[..4].eq_ignore_ascii_case("rgb(") {
        return parse_rgb_args(&s[4..]);
    }
    let lower = s.to_ascii_lowercase();
    NAMED_COLORS
        .binary_search_by(|(n, _)| (*n).cmp(lower.as_str()))
        .ok()
        .map(|i| {
            let v = NAMED_COLORS[i].1;
            Rgb((v >> 16) as u8, (v >> 8) as u8, v as u8)
        })
}

fn parse_hex(h: &str) -> Option<Rgb> {
    if !h.bytes().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let d = |c: u8| (c as char).to_digit(16).unwrap() as u8;
    let b = h.as_bytes();
    match b.len() {
        3 => Some(Rgb(d(b[0]) * 17, d(b[1]) * 17, d(b[2]) * 17)),
        6 => Some(Rgb(d(b[0]) * 16 + d(b[1]), d(b[2]) * 16 + d(b[3]), d(b[4]) * 16 + d(b[5]))),
        _ => None,
    }
}

fn parse_rgb_args(s: &str) -> Option<Rgb> {
    let close = s.find(')')?;
    let inner = &s[..close];
    let mut out = [0u8; 3];
    let mut count = 0;
    for tok in inner.split(|c: char| c == ',' || c.is_ascii_whitespace()).filter(|t| !t.is_empty()) {
        if count == 3 {
            return None;
        }
        let (v, used) = parse_number(tok)?;
        let v = match &tok[used..] {
            "" => v.clamp(0.0, 255.0),
            "%" => v.clamp(0.0, 100.0) * 255.0 / 100.0,
            _ => return None,
        };
        out[count] = v.round() as u8;
        count += 1;
    }
    if count == 3 {
        Some(Rgb(out[0], out[1], out[2]))
    } else {
        None
    }
}

/// The 147 SVG 1.1 colour keywords, sorted by name, with `0xRRGGBB` values.
static NAMED_COLORS: [(&str, u32); 147] = [
    ("aliceblue", 0xf0f8ff),
    ("antiquewhite", 0xfaebd7),
    ("aqua", 0x00ffff),
    ("aquamarine", 0x7fffd4),
    ("azure", 0xf0ffff),
    ("beige", 0xf5f5dc),
    ("bisque", 0xffe4c4),
    ("black", 0x000000),
    ("blanchedalmond", 0xffebcd),
    ("blue", 0x0000ff),
    ("blueviolet", 0x8a2be2),
    ("brown", 0xa52a2a),
    ("burlywood", 0xdeb887),
    ("cadetblue", 0x5f9ea0),
    ("chartreuse", 0x7fff00),
    ("chocolate", 0xd2691e),
    ("coral", 0xff7f50),
    ("cornflowerblue", 0x6495ed),
    ("cornsilk", 0xfff8dc),
    ("crimson", 0xdc143c),
    ("cyan", 0x00ffff),
    ("darkblue", 0x00008b),
    ("darkcyan", 0x008b8b),
    ("darkgoldenrod", 0xb8860b),
    ("darkgray", 0xa9a9a9),
    ("darkgreen", 0x006400),
    ("darkgrey", 0xa9a9a9),
    ("darkkhaki", 0xbdb76b),
    ("darkmagenta", 0x8b008b),
    ("darkolivegreen", 0x556b2f),
    ("darkorange", 0xff8c00),
    ("darkorchid", 0x9932cc),
    ("darkred", 0x8b0000),
    ("darksalmon", 0xe9967a),
    ("darkseagreen", 0x8fbc8f),
    ("darkslateblue", 0x483d8b),
    ("darkslategray", 0x2f4f4f),
    ("darkslategrey", 0x2f4f4f),
    ("darkturquoise", 0x00ced1),
    ("darkviolet", 0x9400d3),
    ("deeppink", 0xff1493),
    ("deepskyblue", 0x00bfff),
    ("dimgray", 0x696969),
    ("dimgrey", 0x696969),
    ("dodgerblue", 0x1e90ff),
    ("firebrick", 0xb22222),
    ("floralwhite", 0xfffaf0),
    ("forestgreen", 0x228b22),
    ("fuchsia", 0xff00ff),
    ("gainsboro", 0xdcdcdc),
    ("ghostwhite", 0xf8f8ff),
    ("gold", 0xffd700),
    ("goldenrod", 0xdaa520),
    ("gray", 0x808080),
    ("green", 0x008000),
    ("greenyellow", 0xadff2f),
    ("grey", 0x808080),
    ("honeydew", 0xf0fff0),
    ("hotpink", 0xff69b4),
    ("indianred", 0xcd5c5c),
    ("indigo", 0x4b0082),
    ("ivory", 0xfffff0),
    ("khaki", 0xf0e68c),
    ("lavender", 0xe6e6fa),
    ("lavenderblush", 0xfff0f5),
    ("lawngreen", 0x7cfc00),
    ("lemonchiffon", 0xfffacd),
    ("lightblue", 0xadd8e6),
    ("lightcoral", 0xf08080),
    ("lightcyan", 0xe0ffff),
    ("lightgoldenrodyellow", 0xfafad2),
    ("lightgray", 0xd3d3d3),
    ("lightgreen", 0x90ee90),
    ("lightgrey", 0xd3d3d3),
    ("lightpink", 0xffb6c1),
    ("lightsalmon", 0xffa07a),
    ("lightseagreen", 0x20b2aa),
    ("lightskyblue", 0x87cefa),
    ("lightslategray", 0x778899),
    ("lightslategrey", 0x778899),
    ("lightsteelblue", 0xb0c4de),
    ("lightyellow", 0xffffe0),
    ("lime", 0x00ff00),
    ("limegreen", 0x32cd32),
    ("linen", 0xfaf0e6),
    ("magenta", 0xff00ff),
    ("maroon", 0x800000),
    ("mediumaquamarine", 0x66cdaa),
    ("mediumblue", 0x0000cd),
    ("mediumorchid", 0xba55d3),
    ("mediumpurple", 0x9370db),
    ("mediumseagreen", 0x3cb371),
    ("mediumslateblue", 0x7b68ee),
    ("mediumspringgreen", 0x00fa9a),
    ("mediumturquoise", 0x48d1cc),
    ("mediumvioletred", 0xc71585),
    ("midnightblue", 0x191970),
    ("mintcream", 0xf5fffa),
    ("mistyrose", 0xffe4e1),
    ("moccasin", 0xffe4b5),
    ("navajowhite", 0xffdead),
    ("navy", 0x000080),
    ("oldlace", 0xfdf5e6),
    ("olive", 0x808000),
    ("olivedrab", 0x6b8e23),
    ("orange", 0xffa500),
    ("orangered", 0xff4500),
    ("orchid", 0xda70d6),
    ("palegoldenrod", 0xeee8aa),
    ("palegreen", 0x98fb98),
    ("paleturquoise", 0xafeeee),
    ("palevioletred", 0xdb7093),
    ("papayawhip", 0xffefd5),
    ("peachpuff", 0xffdab9),
    ("peru", 0xcd853f),
    ("pink", 0xffc0cb),
    ("plum", 0xdda0dd),
    ("powderblue", 0xb0e0e6),
    ("purple", 0x800080),
    ("red", 0xff0000),
    ("rosybrown", 0xbc8f8f),
    ("royalblue", 0x4169e1),
    ("saddlebrown", 0x8b4513),
    ("salmon", 0xfa8072),
    ("sandybrown", 0xf4a460),
    ("seagreen", 0x2e8b57),
    ("seashell", 0xfff5ee),
    ("sienna", 0xa0522d),
    ("silver", 0xc0c0c0),
    ("skyblue", 0x87ceeb),
    ("slateblue", 0x6a5acd),
    ("slategray", 0x708090),
    ("slategrey", 0x708090),
    ("snow", 0xfffafa),
    ("springgreen", 0x00ff7f),
    ("steelblue", 0x4682b4),
    ("tan", 0xd2b48c),
    ("teal", 0x008080),
    ("thistle", 0xd8bfd8),
    ("tomato", 0xff6347),
    ("turquoise", 0x40e0d0),
    ("violet", 0xee82ee),
    ("wheat", 0xf5deb3),
    ("white", 0xffffff),
    ("whitesmoke", 0xf5f5f5),
    ("yellow", 0xffff00),
    ("yellowgreen", 0x9acd32),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn table_is_sorted_for_binary_search() {
        assert!(NAMED_COLORS.windows(2).all(|w| w[0].0 < w[1].0));
    }

    #[test]
    fn hex_forms() {
        assert_eq!(parse_color("#f39"), Some(Rgb(255, 51, 153)));
        assert_eq!(parse_color("#12AB78"), Some(Rgb(0x12, 0xab, 0x78)));
        assert_eq!(parse_color("#12AB7"), None);
    }

    #[test]
    fn rgb_forms() {
        assert_eq!(parse_color("rgb(10, 200, 30)"), Some(Rgb(10, 200, 30)));
        assert_eq!(parse_color("rgb(300 -5 0.5)"), Some(Rgb(255, 0, 1)));
        assert_eq!(parse_color("rgb(20%, 45%, 90%)"), Some(Rgb(51, 115, 230)));
        assert_eq!(parse_color("RGB(0,0)"), None);
    }

    #[test]
    fn keywords_and_paints() {
        assert_eq!(parse_color("DarkSlateGray"), Some(Rgb(47, 79, 79)));
        assert_eq!(parse_paint("NONE"), Some(Paint::None));
        assert_eq!(parse_paint("currentColor"), Some(Paint::CurrentColor));
        assert_eq!(parse_paint("bogus"), None);
    }
}
