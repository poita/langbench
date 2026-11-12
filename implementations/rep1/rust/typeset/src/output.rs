//! Output items, the page records and the formatting of `layout.txt` and
//! `report.txt`.

use crate::metrics::FaceId;
use crate::stats::Stats;
use std::fmt::Write;

/// The region of the page an item belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Region {
    Header,
    Float,
    Body,
    Footnote,
    Footer,
}

impl Region {
    fn name(self) -> &'static str {
        match self {
            Region::Header => "header",
            Region::Float => "float",
            Region::Body => "body",
            Region::Footnote => "footnote",
            Region::Footer => "footer",
        }
    }

    fn rank(self) -> u8 {
        self as u8
    }
}

/// What an output item is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OutKind {
    Text { face: FaceId, size: i64, x: i64, y: i64, width: i64, text: String },
    Rule { x: i64, y: i64, width: i64, thickness: i64 },
    Box { x: i64, y: i64, width: i64, height: i64 },
}

/// One placed item.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutItem {
    pub region: Region,
    pub kind: OutKind,
}

impl OutItem {
    pub fn text(region: Region, face: FaceId, size: i64, x: i64, y: i64, width: i64, text: &str) -> OutItem {
        OutItem { region, kind: OutKind::Text { face, size, x, y, width, text: text.to_string() } }
    }

    fn format(&self) -> String {
        let r = self.region.name();
        match &self.kind {
            OutKind::Text { face, size, x, y, width, text } => {
                let mut esc = String::with_capacity(text.len());
                for c in text.chars() {
                    match c {
                        '\\' => esc.push_str("\\\\"),
                        '"' => esc.push_str("\\\""),
                        c => esc.push(c),
                    }
                }
                format!("  text {r} {} {size} {x} {y} {width} \"{esc}\"", face.name())
            }
            OutKind::Rule { x, y, width, thickness } => format!("  rule {r} {x} {y} {width} {thickness}"),
            OutKind::Box { x, y, width, height } => format!("  box {r} {x} {y} {width} {height}"),
        }
    }

    fn sort_key(&self) -> (u8, i64, i64, u8) {
        let (y, x, k) = match &self.kind {
            OutKind::Text { x, y, .. } => (*y, *x, 0),
            OutKind::Rule { x, y, .. } => (*y, *x, 1),
            OutKind::Box { x, y, .. } => (*y, *x, 2),
        };
        (self.region.rank(), y, x, k)
    }
}

/// A finished page.
#[derive(Clone, Debug)]
pub struct PageRec {
    pub items: Vec<OutItem>,
    pub label: String,
    /// The number the label stands for (decides odd/even headers).
    pub label_value: i64,
    pub front: bool,
    /// Current `{chapter}` / `{section}` texts.
    pub chapter: String,
    pub section: String,
}

/// Page geometry for the `page` records.
#[derive(Clone, Copy, Debug)]
pub struct PageGeometry {
    pub width: i64,
    pub height: i64,
    pub body_x: i64,
    pub body_y: i64,
    pub body_width: i64,
    pub body_height: i64,
}

/// Formats `layout.txt`.
pub fn format_layout(pages: &[PageRec], g: &PageGeometry) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "layout 1");
    let _ = writeln!(out, "pages {}", pages.len());
    for (i, p) in pages.iter().enumerate() {
        let _ = writeln!(
            out,
            "page {} {} {} {} {} {} {} {}",
            i + 1,
            p.label,
            g.width,
            g.height,
            g.body_x,
            g.body_y,
            g.body_width,
            g.body_height
        );
        let mut lines: Vec<((u8, i64, i64, u8), String)> =
            p.items.iter().map(|it| (it.sort_key(), it.format())).collect();
        lines.sort();
        for (_, l) in lines {
            out.push_str(&l);
            out.push('\n');
        }
    }
    out
}

/// Formats `report.txt`.
pub fn format_report(stats: &Stats, pages: usize, front_pages: usize) -> String {
    let mut out = String::new();
    let mut line = |k: &str, v: String| {
        let _ = writeln!(out, "{k} {v}");
    };
    line("report", "1".into());
    line("pages", pages.to_string());
    line("front-pages", front_pages.to_string());
    line("body-pages", (pages - front_pages).to_string());
    line("lines", stats.lines.to_string());
    line("paragraphs", stats.paragraphs.to_string());
    line("headings", stats.headings.to_string());
    line("tables", stats.tables.to_string());
    line("figures", stats.figures.to_string());
    line("footnotes", stats.footnotes.to_string());
    line("footnote-split-lines", stats.footnote_split_lines.to_string());
    line("hyphenated-lines", stats.hyphenated_lines.to_string());
    line("overfull-lines", stats.overfull_lines.to_string());
    line("emergency-lists", stats.emergency_lists.to_string());
    line("total-demerits", stats.total_demerits.to_string());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_items_are_escaped() {
        let it = OutItem::text(Region::Body, FaceId(0), 10000, 1, 2, 3, "a\"b\\c");
        assert_eq!(it.format(), "  text body serif 10000 1 2 3 \"a\\\"b\\\\c\"");
    }

    #[test]
    fn items_sort_by_region_then_y_then_x() {
        let g = PageGeometry { width: 1, height: 1, body_x: 0, body_y: 0, body_width: 1, body_height: 1 };
        let page = PageRec {
            items: vec![
                OutItem::text(Region::Footer, FaceId(0), 1, 0, 0, 0, "f"),
                OutItem::text(Region::Body, FaceId(0), 1, 5, 2, 0, "b2"),
                OutItem::text(Region::Body, FaceId(0), 1, 1, 2, 0, "b1"),
                OutItem::text(Region::Header, FaceId(0), 1, 9, 9, 0, "h"),
            ],
            label: "1".into(),
            label_value: 1,
            front: false,
            chapter: String::new(),
            section: String::new(),
        };
        let s = format_layout(&[page], &g);
        let order: Vec<&str> = s.lines().skip(3).collect();
        assert!(order[0].contains("header") && order[1].contains("\"b1\"") && order[2].contains("\"b2\""));
        assert!(order[3].contains("footer"));
    }
}
