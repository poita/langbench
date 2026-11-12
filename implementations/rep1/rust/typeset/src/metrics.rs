//! Font faces: glyph advances, kerning pairs and vertical metrics, read from
//! the `.cfm` (Codexa Font Metrics) files.

use crate::units::scale;
use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::Path;

/// A font family.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Family {
    Serif,
    Sans,
    Mono,
}

impl Family {
    /// Parses `serif`, `sans` or `mono`.
    pub fn parse(s: &str) -> Option<Family> {
        match s {
            "serif" => Some(Family::Serif),
            "sans" => Some(Family::Sans),
            "mono" => Some(Family::Mono),
            _ => None,
        }
    }
}

/// Identifies one of the nine faces; an index into [`Fonts`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct FaceId(pub u8);

/// File/face names in [`FaceId`] order.
pub const FACE_NAMES: [&str; 9] = [
    "serif",
    "serif-bold",
    "serif-italic",
    "serif-bold-italic",
    "sans",
    "sans-bold",
    "sans-italic",
    "sans-bold-italic",
    "mono",
];

impl FaceId {
    /// Resolves a (family, bold, italic) triple to a face.
    pub fn resolve(family: Family, bold: bool, italic: bool) -> FaceId {
        let base = match family {
            Family::Serif => 0,
            Family::Sans => 4,
            Family::Mono => return FaceId(8),
        };
        FaceId(base + bold as u8 + 2 * italic as u8)
    }

    pub fn name(self) -> &'static str {
        FACE_NAMES[self.0 as usize]
    }

    pub fn is_mono(self) -> bool {
        self.0 == 8
    }
}

/// The metrics of one face. All values are in thousandths of an em.
#[derive(Clone, Debug, Default)]
pub struct Face {
    pub ascent: i64,
    pub descent: i64,
    pub space: i64,
    pub stretch: i64,
    pub shrink: i64,
    pub extra: i64,
    pub default_advance: i64,
    glyphs: HashMap<u32, i64>,
    kerns: HashMap<(u32, u32), i64>,
}

fn strip(line: &str) -> &str {
    let line = match line.find('#') {
        Some(i) => &line[..i],
        None => line,
    };
    line.trim_matches(|c| c == ' ' || c == '\t')
}

impl Face {
    /// Parses the text of a `.cfm` file. Unknown or malformed records are
    /// ignored (the shipped files are well formed).
    pub fn parse(text: &str) -> Face {
        let mut f = Face::default();
        for raw in text.split('\n') {
            let line = strip(raw);
            if line.is_empty() {
                continue;
            }
            let t: Vec<&str> = line.split([' ', '\t']).filter(|s| !s.is_empty()).collect();
            let num = |i: usize| t.get(i).and_then(|s| s.parse::<i64>().ok()).unwrap_or(0);
            match t[0] {
                "ascent" => f.ascent = num(1),
                "descent" => f.descent = num(1),
                "space" => {
                    f.space = num(1);
                    f.stretch = num(2);
                    f.shrink = num(3);
                }
                "extra" => f.extra = num(1),
                "default" => f.default_advance = num(1),
                "glyph" => {
                    f.glyphs.insert(num(1) as u32, num(2));
                }
                "kern" => {
                    f.kerns.insert((num(1) as u32, num(2) as u32), num(3));
                }
                _ => {}
            }
        }
        f
    }

    /// Advance of a character in glyph-space units.
    pub fn adv(&self, c: char) -> i64 {
        *self.glyphs.get(&(c as u32)).unwrap_or(&self.default_advance)
    }

    /// Kern between an ordered pair, in glyph-space units.
    pub fn kern(&self, a: char, b: char) -> i64 {
        *self.kerns.get(&(a as u32, b as u32)).unwrap_or(&0)
    }

    /// Width of a run of text at `size`: advances and kerns are summed in
    /// glyph space and scaled once.
    pub fn text_width(&self, text: &str, size: i64) -> i64 {
        let mut units = 0;
        let mut prev: Option<char> = None;
        for c in text.chars() {
            units += self.adv(c);
            if let Some(p) = prev {
                units += self.kern(p, c);
            }
            prev = Some(c);
        }
        scale(units, size)
    }

    /// Scaled ascent at `size`.
    pub fn ascent_at(&self, size: i64) -> i64 {
        scale(self.ascent, size)
    }

    /// Scaled descent at `size`.
    pub fn descent_at(&self, size: i64) -> i64 {
        scale(self.descent, size)
    }
}

/// All nine faces.
#[derive(Clone, Debug)]
pub struct Fonts {
    faces: Vec<Face>,
}

impl Fonts {
    /// Loads `faces/<name>.cfm` for every face from `dir` (the `faces`
    /// directory itself).
    pub fn load(dir: &Path) -> io::Result<Fonts> {
        let mut faces = Vec::new();
        for name in FACE_NAMES {
            let text = fs::read_to_string(dir.join(format!("{name}.cfm")))?;
            faces.push(Face::parse(&text));
        }
        Ok(Fonts { faces })
    }

    /// Builds a font set from the texts of the nine `.cfm` files, in
    /// [`FACE_NAMES`] order.
    pub fn from_texts(texts: &[&str]) -> Fonts {
        Fonts { faces: texts.iter().map(|t| Face::parse(t)).collect() }
    }

    pub fn face(&self, id: FaceId) -> &Face {
        &self.faces[id.0 as usize]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "cfm 1\nface t\nascent 700\ndescent 200\nspace 250 100 50\nextra 100\ndefault 500\nglyph 65 600 # A\nglyph 66 400\nkern 65 66 -100\n";

    #[test]
    fn parses_records() {
        let f = Face::parse(SAMPLE);
        assert_eq!(f.ascent, 700);
        assert_eq!((f.space, f.stretch, f.shrink), (250, 100, 50));
        assert_eq!(f.adv('A'), 600);
        assert_eq!(f.adv('z'), 500);
        assert_eq!(f.kern('A', 'B'), -100);
        assert_eq!(f.kern('B', 'A'), 0);
    }

    #[test]
    fn width_scales_once() {
        let f = Face::parse(SAMPLE);
        // 600 + 400 - 100 = 900 units at 10000 -> 9000
        assert_eq!(f.text_width("AB", 10000), 9000);
        assert_eq!(f.text_width("", 10000), 0);
    }

    #[test]
    fn face_resolution() {
        assert_eq!(FaceId::resolve(Family::Serif, false, false).name(), "serif");
        assert_eq!(FaceId::resolve(Family::Sans, true, true).name(), "sans-bold-italic");
        assert_eq!(FaceId::resolve(Family::Mono, true, true).name(), "mono");
    }
}
