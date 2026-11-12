//! The `settings.cfg` file: parsing, validation, defaults and derived page
//! geometry.

use crate::error::{Code, Error};
use crate::metrics::Family;
use crate::values::{parse_integer, parse_length};

/// Paragraph / caption / heading alignment.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Align {
    Justify,
    Left,
    Right,
    Center,
}

impl Align {
    pub fn parse(s: &str) -> Option<Align> {
        match s {
            "justify" => Some(Align::Justify),
            "left" => Some(Align::Left),
            "right" => Some(Align::Right),
            "center" => Some(Align::Center),
            _ => None,
        }
    }
}

/// Which hyphenation pattern set is active.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PatternSet {
    English,
    Minimal,
}

/// A placeholder usable in header and footer text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Placeholder {
    Page,
    Pages,
    Title,
    Author,
    Date,
    Chapter,
    Section,
}

/// One piece of a text setting.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TextPart {
    Lit(String),
    Ph(Placeholder),
}

/// A parsed `text` value: literal runs and placeholders.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Template(pub Vec<TextPart>);

impl Template {
    fn has_placeholder(&self) -> bool {
        self.0.iter().any(|p| matches!(p, TextPart::Ph(_)))
    }

    /// The literal text of a template without placeholders.
    pub fn as_literal(&self) -> String {
        let mut s = String::new();
        for p in &self.0 {
            if let TextPart::Lit(t) = p {
                s.push_str(t);
            }
        }
        s
    }
}

/// The six header/footer slots, for odd and even pages.
#[derive(Clone, Debug, Default)]
pub struct Slots {
    /// Order: header left/center/right, footer left/center/right.
    pub plain: [Template; 6],
    pub even: [Template; 6],
}

/// All layout settings, in millipoints where they are lengths.
#[derive(Clone, Debug)]
pub struct Settings {
    pub page_width: i64,
    pub page_height: i64,
    pub margin_top: i64,
    pub margin_bottom: i64,
    pub margin_left: i64,
    pub margin_right: i64,
    pub header_baseline: i64,
    pub footer_baseline: i64,
    pub page_start: i64,

    pub body_font: Family,
    pub body_size: i64,
    pub leading: i64,
    pub line_skip: i64,
    pub align: Align,
    pub par_indent: i64,
    pub par_space: i64,

    pub tolerance: i64,
    pub line_penalty: i64,
    pub hyphen_penalty: i64,
    pub ex_hyphen_penalty: i64,
    pub adj_demerits: i64,
    pub double_hyphen_demerits: i64,
    pub final_hyphen_demerits: i64,
    pub ragged_stretch: i64,
    pub hyphenate: bool,
    pub hyphen_patterns: PatternSet,

    pub heading_font: Family,
    pub heading_bold: bool,
    pub heading_italic: bool,
    pub heading_align: Align,
    pub heading_number: bool,
    pub heading_number_gap: i64,
    pub h1_newpage: bool,
    /// Indexed by level - 1.
    pub h_size: [i64; 4],
    pub h_leading: [i64; 4],
    pub h_space_before: [i64; 4],
    pub h_space_after: [i64; 4],

    pub list_indent: i64,
    pub list_marker_gap: i64,
    pub list_space: i64,
    pub list_item_space: i64,
    pub quote_indent: i64,
    pub quote_space: i64,
    pub pre_font: Family,
    pub pre_size: i64,
    pub pre_leading: i64,
    pub pre_indent: i64,
    pub pre_space: i64,

    pub table_col_gap: i64,
    pub table_row_space: i64,
    pub table_rule_space: i64,
    pub table_rule_thickness: i64,
    pub table_space: i64,
    pub table_leading: i64,
    pub rule_thickness: i64,
    pub rule_space: i64,

    pub footnote_font: Family,
    pub footnote_size: i64,
    pub footnote_leading: i64,
    pub footnote_indent: i64,
    pub footnote_mark_gap: i64,
    pub footnote_mark_size: i64,
    pub footnote_mark_raise: i64,
    pub footnote_item_space: i64,
    pub footnote_rule_width: i64,
    pub footnote_rule_thickness: i64,
    pub footnote_space_before: i64,
    pub footnote_space_after: i64,
    pub footnote_min_split: i64,
    pub footnote_max_height: i64,
    pub mark_size: i64,
    pub mark_raise: i64,

    pub figure_width: i64,
    pub figure_frame: bool,
    pub figure_caption_font: Family,
    pub figure_caption_size: i64,
    pub figure_caption_leading: i64,
    pub figure_caption_align: Align,
    pub figure_caption_space: i64,
    pub figure_caption_prefix: String,
    pub figure_caption_gap: i64,
    pub float_space_after: i64,
    pub float_min_body: i64,

    pub widows: i64,
    pub orphans: i64,
    pub keep_with_next: bool,

    pub toc_depth: i64,
    pub toc_font: Family,
    pub toc_size: i64,
    pub toc_leading: i64,
    pub toc_indent: i64,
    pub toc_number_gap: i64,
    pub toc_reserve: i64,
    pub toc_leader: String,
    pub toc_leader_gap: i64,
    pub toc_entry_space: i64,
    pub toc_title: String,
    pub toc_title_font: Family,
    pub toc_title_size: i64,
    pub toc_title_space_after: i64,

    pub header_font: Family,
    pub header_size: i64,
    pub slots: Slots,
}

impl Default for Settings {
    fn default() -> Settings {
        let pt = |n: i64| n * 1000;
        Settings {
            page_width: pt(612),
            page_height: pt(792),
            margin_top: pt(72),
            margin_bottom: pt(72),
            margin_left: pt(72),
            margin_right: pt(72),
            header_baseline: pt(36),
            footer_baseline: pt(792 - 36),
            page_start: 1,
            body_font: Family::Serif,
            body_size: pt(10),
            leading: pt(12),
            line_skip: pt(1),
            align: Align::Justify,
            par_indent: pt(18),
            par_space: 0,
            tolerance: 1000,
            line_penalty: 10,
            hyphen_penalty: 50,
            ex_hyphen_penalty: 50,
            adj_demerits: 10000,
            double_hyphen_demerits: 10000,
            final_hyphen_demerits: 5000,
            ragged_stretch: 3,
            hyphenate: true,
            hyphen_patterns: PatternSet::English,
            heading_font: Family::Sans,
            heading_bold: true,
            heading_italic: false,
            heading_align: Align::Left,
            heading_number: true,
            heading_number_gap: pt(6),
            h1_newpage: false,
            h_size: [pt(20), pt(14), pt(12), pt(11)],
            h_leading: [pt(24), pt(17), pt(14), pt(13)],
            h_space_before: [pt(18), pt(14), pt(12), pt(11)],
            h_space_after: [pt(9), pt(7), pt(6), pt(5)],
            list_indent: pt(18),
            list_marker_gap: pt(4),
            list_space: pt(6),
            list_item_space: 0,
            quote_indent: pt(18),
            quote_space: pt(6),
            pre_font: Family::Mono,
            pre_size: pt(9),
            pre_leading: pt(11),
            pre_indent: 0,
            pre_space: pt(6),
            table_col_gap: pt(8),
            table_row_space: pt(2),
            table_rule_space: pt(2),
            table_rule_thickness: 400,
            table_space: pt(6),
            table_leading: pt(12),
            rule_thickness: 500,
            rule_space: pt(6),
            footnote_font: Family::Serif,
            footnote_size: pt(8),
            footnote_leading: pt(10),
            footnote_indent: pt(10),
            footnote_mark_gap: pt(2),
            footnote_mark_size: pt(6),
            footnote_mark_raise: pt(2),
            footnote_item_space: pt(2),
            footnote_rule_width: pt(120),
            footnote_rule_thickness: 400,
            footnote_space_before: pt(6),
            footnote_space_after: pt(3),
            footnote_min_split: 1,
            footnote_max_height: (pt(792 - 144)) / 2,
            mark_size: pt(7),
            mark_raise: pt(3),
            figure_width: 0,
            figure_frame: true,
            figure_caption_font: Family::Serif,
            figure_caption_size: pt(9),
            figure_caption_leading: pt(11),
            figure_caption_align: Align::Center,
            figure_caption_space: pt(4),
            figure_caption_prefix: "Figure".to_string(),
            figure_caption_gap: pt(4),
            float_space_after: pt(12),
            float_min_body: pt(24),
            widows: 2,
            orphans: 2,
            keep_with_next: true,
            toc_depth: 2,
            toc_font: Family::Serif,
            toc_size: pt(10),
            toc_leading: pt(14),
            toc_indent: pt(18),
            toc_number_gap: pt(6),
            toc_reserve: pt(30),
            toc_leader: ".".to_string(),
            toc_leader_gap: pt(3),
            toc_entry_space: 0,
            toc_title: "Contents".to_string(),
            toc_title_font: Family::Sans,
            toc_title_size: pt(20),
            toc_title_space_after: pt(12),
            header_font: Family::Sans,
            header_size: pt(9),
            slots: Slots::default(),
        }
    }
}

impl Settings {
    pub fn body_x(&self) -> i64 {
        self.margin_left
    }
    pub fn body_y(&self) -> i64 {
        self.margin_top
    }
    pub fn body_width(&self) -> i64 {
        self.page_width - self.margin_left - self.margin_right
    }
    pub fn body_height(&self) -> i64 {
        self.page_height - self.margin_top - self.margin_bottom
    }
    pub fn body_bottom(&self) -> i64 {
        self.body_y() + self.body_height()
    }

    /// Parses `settings.cfg` text (or the defaults when `None`).
    pub fn parse(text: Option<&str>) -> Result<Settings, Error> {
        let mut s = Settings::default();
        let mut assigned: Vec<String> = Vec::new();
        let mut even_assigned = [false; 6];
        let mut footer_baseline: Option<i64> = None;
        let mut max_height: Option<i64> = None;
        let mut geom_pos: Option<(usize, usize)> = None;

        if let Some(text) = text {
            let mut lines: Vec<&str> = text.split('\n').collect();
            if lines.last() == Some(&"") {
                lines.pop();
            }
            for (idx, raw) in lines.iter().enumerate() {
                let ln = idx + 1;
                let c: Vec<char> = raw.chars().collect();
                let ws = |ch: char| ch == ' ' || ch == '\t';
                let mut p = 0;
                while p < c.len() && ws(c[p]) {
                    p += 1;
                }
                if p == c.len() || c[p] == '#' {
                    continue;
                }
                let mut k = p;
                while k < c.len() && (c[k].is_ascii_lowercase() || c[k].is_ascii_digit() || c[k] == '-') {
                    k += 1;
                }
                let mut q = k;
                while q < c.len() && ws(c[q]) {
                    q += 1;
                }
                if k == p || q >= c.len() || c[q] != '=' {
                    return Err(Error::settings(ln, p + 1, Code::BadSyntax));
                }
                let key: String = c[p..k].iter().collect();
                let mut v0 = q + 1;
                while v0 < c.len() && ws(c[v0]) {
                    v0 += 1;
                }
                let mut v1 = c.len();
                while v1 > v0 && ws(c[v1 - 1]) {
                    v1 -= 1;
                }
                let value: String = c[v0..v1].iter().collect();
                if assigned.contains(&key) {
                    return Err(Error::settings(ln, p + 1, Code::DuplicateSetting));
                }
                let mut ctx = Assign {
                    even_assigned: &mut even_assigned,
                    footer_baseline: &mut footer_baseline,
                    max_height: &mut max_height,
                };
                match s.assign(&key, &value, &mut ctx) {
                    Ok(()) => {}
                    Err(None) => return Err(Error::settings(ln, p + 1, Code::UnknownSetting)),
                    Err(Some((code, off))) => {
                        return Err(Error::settings(ln, v0 + 1 + off, code));
                    }
                }
                if matches!(
                    key.as_str(),
                    "page-width" | "page-height" | "margin-top" | "margin-bottom" | "margin-left" | "margin-right"
                ) {
                    geom_pos = Some((ln, v0 + 1));
                }
                assigned.push(key);
            }
        }

        if s.body_width() < 36000 || s.body_height() < 36000 {
            let (l, c) = geom_pos.unwrap_or((0, 0));
            return Err(Error::settings(l, c, Code::BadValue));
        }
        s.footer_baseline = footer_baseline.unwrap_or(s.page_height - 36000);
        s.footnote_max_height = max_height.unwrap_or(s.body_height() / 2);
        for (i, assigned) in even_assigned.iter().enumerate() {
            if !assigned {
                s.slots.even[i] = s.slots.plain[i].clone();
            }
        }
        Ok(s)
    }
}

type VErr = (Code, usize);

struct Assign<'a> {
    even_assigned: &'a mut [bool; 6],
    footer_baseline: &'a mut Option<i64>,
    max_height: &'a mut Option<i64>,
}

fn range(n: i64, min: i64, max: i64) -> Result<i64, VErr> {
    if n < min || n > max {
        Err((Code::BadValue, 0))
    } else {
        Ok(n)
    }
}

fn length(v: &str, min: i64, max: i64) -> Result<i64, VErr> {
    range(parse_length(v).ok_or((Code::BadLength, 0))?, min, max)
}

fn len(v: &str) -> Result<i64, VErr> {
    length(v, 0, i64::MAX)
}

fn len_min(v: &str, min: i64) -> Result<i64, VErr> {
    length(v, min, i64::MAX)
}

fn size(v: &str) -> Result<i64, VErr> {
    length(v, 1000, 200000)
}

fn integer(v: &str, min: i64, max: i64) -> Result<i64, VErr> {
    range(parse_integer(v).ok_or((Code::BadInteger, 0))?, min, max)
}

fn boolean(v: &str) -> Result<bool, VErr> {
    match v {
        "on" => Ok(true),
        "off" => Ok(false),
        _ => Err((Code::BadBoolean, 0)),
    }
}

fn family(v: &str) -> Result<Family, VErr> {
    Family::parse(v).ok_or((Code::UnknownFont, 0))
}

fn align(v: &str) -> Result<Align, VErr> {
    Align::parse(v).ok_or((Code::BadEnum, 0))
}

/// Parses a `text` value in a single left-to-right scan.
fn text(v: &str) -> Result<Template, VErr> {
    let c: Vec<char> = v.chars().collect();
    let mut parts: Vec<TextPart> = Vec::new();
    let mut lit = String::new();
    let mut i = 0;
    while i < c.len() {
        match c[i] {
            '\\' => match c.get(i + 1) {
                Some(&e) if e == '{' || e == '}' || e == '\\' => {
                    lit.push(e);
                    i += 2;
                }
                _ => return Err((Code::BadEscape, i)),
            },
            '{' => {
                let Some(rel) = c[i + 1..].iter().position(|&x| x == '}') else {
                    return Err((Code::UnknownPlaceholder, i));
                };
                let j = i + 1 + rel;
                let name: String = c[i + 1..j].iter().collect();
                let ph = match name.as_str() {
                    "page" => Placeholder::Page,
                    "pages" => Placeholder::Pages,
                    "title" => Placeholder::Title,
                    "author" => Placeholder::Author,
                    "date" => Placeholder::Date,
                    "chapter" => Placeholder::Chapter,
                    "section" => Placeholder::Section,
                    _ => return Err((Code::UnknownPlaceholder, i)),
                };
                if !lit.is_empty() {
                    parts.push(TextPart::Lit(std::mem::take(&mut lit)));
                }
                parts.push(TextPart::Ph(ph));
                i = j + 1;
            }
            '}' => return Err((Code::StrayBrace, i)),
            ch => {
                lit.push(ch);
                i += 1;
            }
        }
    }
    if !lit.is_empty() {
        parts.push(TextPart::Lit(lit));
    }
    Ok(Template(parts))
}

/// A text value in which placeholders are not allowed.
fn plain_text(v: &str) -> Result<String, VErr> {
    let t = text(v)?;
    if t.has_placeholder() {
        return Err((Code::BadValue, 0));
    }
    Ok(t.as_literal())
}

impl Settings {
    /// Applies one assignment. `Err(None)` means unknown key.
    fn assign(&mut self, key: &str, v: &str, a: &mut Assign) -> Result<(), Option<VErr>> {
        // Heading level keys: h1-size and friends.
        if key.len() > 3 && key.starts_with('h') && matches!(key.as_bytes()[1], b'1'..=b'4') && key.as_bytes()[2] == b'-' {
            let lvl = (key.as_bytes()[1] - b'1') as usize;
            let handled = match &key[3..] {
                "size" => {
                    self.h_size[lvl] = size(v)?;
                    true
                }
                "leading" => {
                    self.h_leading[lvl] = len_min(v, 1000)?;
                    true
                }
                "space-before" => {
                    self.h_space_before[lvl] = len(v)?;
                    true
                }
                "space-after" => {
                    self.h_space_after[lvl] = len(v)?;
                    true
                }
                _ => false,
            };
            if handled {
                return Ok(());
            }
        }
        // Header / footer slots.
        for (slot, base) in
            ["header-left", "header-center", "header-right", "footer-left", "footer-center", "footer-right"]
                .iter()
                .enumerate()
        {
            if key == *base {
                self.slots.plain[slot] = text(v)?;
                return Ok(());
            }
            if key.len() == base.len() + 5 && key.starts_with(base) && key.ends_with("-even") {
                self.slots.even[slot] = text(v)?;
                a.even_assigned[slot] = true;
                return Ok(());
            }
        }
        match key {
            "page-width" => self.page_width = len_min(v, 36000)?,
            "page-height" => self.page_height = len_min(v, 36000)?,
            "margin-top" => self.margin_top = len(v)?,
            "margin-bottom" => self.margin_bottom = len(v)?,
            "margin-left" => self.margin_left = len(v)?,
            "margin-right" => self.margin_right = len(v)?,
            "header-baseline" => self.header_baseline = len(v)?,
            "footer-baseline" => *a.footer_baseline = Some(len(v)?),
            "page-start" => self.page_start = integer(v, 1, 3000)?,

            "body-font" => self.body_font = family(v)?,
            "body-size" => self.body_size = size(v)?,
            "leading" => self.leading = len_min(v, 1000)?,
            "line-skip" => self.line_skip = len(v)?,
            "align" => self.align = align(v)?,
            "par-indent" => self.par_indent = len(v)?,
            "par-space" => self.par_space = len(v)?,

            "tolerance" => self.tolerance = integer(v, 0, 10000)?,
            "line-penalty" => self.line_penalty = integer(v, 0, 10000)?,
            "hyphen-penalty" => self.hyphen_penalty = integer(v, -9999, 9999)?,
            "ex-hyphen-penalty" => self.ex_hyphen_penalty = integer(v, -9999, 9999)?,
            "adj-demerits" => self.adj_demerits = integer(v, 0, 1000000)?,
            "double-hyphen-demerits" => self.double_hyphen_demerits = integer(v, 0, 1000000)?,
            "final-hyphen-demerits" => self.final_hyphen_demerits = integer(v, 0, 1000000)?,
            "ragged-stretch" => self.ragged_stretch = integer(v, 0, 100)?,
            "hyphenate" => self.hyphenate = boolean(v)?,
            "hyphen-patterns" => {
                self.hyphen_patterns = match v {
                    "english" => PatternSet::English,
                    "minimal" => PatternSet::Minimal,
                    _ => return Err(Some((Code::UnknownPatterns, 0))),
                }
            }

            "heading-font" => self.heading_font = family(v)?,
            "heading-bold" => self.heading_bold = boolean(v)?,
            "heading-italic" => self.heading_italic = boolean(v)?,
            "heading-align" => self.heading_align = align(v)?,
            "heading-number" => self.heading_number = boolean(v)?,
            "heading-number-gap" => self.heading_number_gap = len(v)?,
            "h1-newpage" => self.h1_newpage = boolean(v)?,

            "list-indent" => self.list_indent = len(v)?,
            "list-marker-gap" => self.list_marker_gap = len(v)?,
            "list-space" => self.list_space = len(v)?,
            "list-item-space" => self.list_item_space = len(v)?,
            "quote-indent" => self.quote_indent = len(v)?,
            "quote-space" => self.quote_space = len(v)?,
            "pre-font" => self.pre_font = family(v)?,
            "pre-size" => self.pre_size = size(v)?,
            "pre-leading" => self.pre_leading = len_min(v, 1000)?,
            "pre-indent" => self.pre_indent = len(v)?,
            "pre-space" => self.pre_space = len(v)?,

            "table-col-gap" => self.table_col_gap = len(v)?,
            "table-row-space" => self.table_row_space = len(v)?,
            "table-rule-space" => self.table_rule_space = len(v)?,
            "table-rule-thickness" => self.table_rule_thickness = len_min(v, 1)?,
            "table-space" => self.table_space = len(v)?,
            "table-leading" => self.table_leading = len_min(v, 1000)?,
            "rule-thickness" => self.rule_thickness = len_min(v, 1)?,
            "rule-space" => self.rule_space = len(v)?,

            "footnote-font" => self.footnote_font = family(v)?,
            "footnote-size" => self.footnote_size = size(v)?,
            "footnote-leading" => self.footnote_leading = len_min(v, 1000)?,
            "footnote-indent" => self.footnote_indent = len(v)?,
            "footnote-mark-gap" => self.footnote_mark_gap = len(v)?,
            "footnote-mark-size" => self.footnote_mark_size = size(v)?,
            "footnote-mark-raise" => self.footnote_mark_raise = len(v)?,
            "footnote-item-space" => self.footnote_item_space = len(v)?,
            "footnote-rule-width" => self.footnote_rule_width = len(v)?,
            "footnote-rule-thickness" => self.footnote_rule_thickness = len_min(v, 1)?,
            "footnote-space-before" => self.footnote_space_before = len(v)?,
            "footnote-space-after" => self.footnote_space_after = len(v)?,
            "footnote-min-split" => self.footnote_min_split = integer(v, 1, 100)?,
            "footnote-max-height" => *a.max_height = Some(len_min(v, 1000)?),
            "mark-size" => self.mark_size = size(v)?,
            "mark-raise" => self.mark_raise = len(v)?,

            "figure-width" => self.figure_width = len(v)?,
            "figure-frame" => self.figure_frame = boolean(v)?,
            "figure-caption-font" => self.figure_caption_font = family(v)?,
            "figure-caption-size" => self.figure_caption_size = size(v)?,
            "figure-caption-leading" => self.figure_caption_leading = len_min(v, 1000)?,
            "figure-caption-align" => self.figure_caption_align = align(v)?,
            "figure-caption-space" => self.figure_caption_space = len(v)?,
            "figure-caption-prefix" => self.figure_caption_prefix = plain_text(v)?,
            "figure-caption-gap" => self.figure_caption_gap = len(v)?,
            "float-space-after" => self.float_space_after = len(v)?,
            "float-min-body" => self.float_min_body = len(v)?,

            "widows" => self.widows = integer(v, 1, 20)?,
            "orphans" => self.orphans = integer(v, 1, 20)?,
            "keep-with-next" => self.keep_with_next = boolean(v)?,

            "toc-depth" => self.toc_depth = integer(v, 0, 4)?,
            "toc-font" => self.toc_font = family(v)?,
            "toc-size" => self.toc_size = size(v)?,
            "toc-leading" => self.toc_leading = len_min(v, 1000)?,
            "toc-indent" => self.toc_indent = len(v)?,
            "toc-number-gap" => self.toc_number_gap = len(v)?,
            "toc-reserve" => self.toc_reserve = len(v)?,
            "toc-leader" => {
                let l = plain_text(v)?;
                let n = l.chars().count();
                if n == 0 || n > 8 || l.contains(' ') {
                    return Err(Some((Code::BadValue, 0)));
                }
                self.toc_leader = l;
            }
            "toc-leader-gap" => self.toc_leader_gap = len(v)?,
            "toc-entry-space" => self.toc_entry_space = len(v)?,
            "toc-title" => self.toc_title = plain_text(v)?,
            "toc-title-font" => self.toc_title_font = family(v)?,
            "toc-title-size" => self.toc_title_size = size(v)?,
            "toc-title-space-after" => self.toc_title_space_after = len(v)?,

            "header-font" => self.header_font = family(v)?,
            "header-size" => self.header_size = size(v)?,
            _ => return Err(None),
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn err(text: &str) -> String {
        Settings::parse(Some(text)).unwrap_err().to_string()
    }

    #[test]
    fn defaults() {
        let s = Settings::parse(None).unwrap();
        assert_eq!(s.body_width(), 468000);
        assert_eq!(s.footer_baseline, 756000);
        assert_eq!(s.footnote_max_height, 324000);
    }

    #[test]
    fn derived_defaults_follow_explicit_settings() {
        let s = Settings::parse(Some("page-height = 400pt\nheader-left = {page}\n")).unwrap();
        assert_eq!(s.footer_baseline, 364000);
        assert_eq!(s.footnote_max_height, 128000);
        assert_eq!(s.slots.even[0], s.slots.plain[0]);
    }

    #[test]
    fn error_positions() {
        assert_eq!(err("page-width = 200pt\nmargin-left = 20px\n"), "settings.cfg:2:15: bad-length");
        assert_eq!(err("nonsense\n"), "settings.cfg:1:1: bad-syntax");
        assert_eq!(err("  frob = 1\n"), "settings.cfg:1:3: unknown-setting");
        assert_eq!(err("widows = 2\nwidows = 3\n"), "settings.cfg:2:1: duplicate-setting");
        assert_eq!(err("hyphenate = yes\n"), "settings.cfg:1:13: bad-boolean");
        assert_eq!(err("hyphenate =\n"), "settings.cfg:1:12: bad-boolean");
        assert_eq!(err("margin-top = -1\n"), "settings.cfg:1:14: bad-value");
    }

    #[test]
    fn text_values() {
        assert_eq!(err("header-left = \\{page}\n"), "settings.cfg:1:21: stray-brace");
        assert_eq!(err("header-left = }\\q\n"), "settings.cfg:1:15: stray-brace");
        assert_eq!(err("header-left = {pa\\ge}\n"), "settings.cfg:1:15: unknown-placeholder");
        assert_eq!(err("header-left = a\\q\n"), "settings.cfg:1:16: bad-escape");
        assert_eq!(err("toc-title = {page}\n"), "settings.cfg:1:13: bad-value");
    }

    #[test]
    fn body_rectangle_check_reports_last_geometry_key() {
        assert_eq!(
            err("margin-left = 300pt\nmargin-right = 300pt\nleading = 12pt\n"),
            "settings.cfg:2:16: bad-value"
        );
    }
}
