//! Horizontal lists: the flattening of inline text into styled units and the
//! construction of boxes, glue and penalties from them.

use crate::ast::{Inline, Tag};
use crate::env::Env;
use crate::metrics::{FaceId, Family};
use crate::patterns::fragment_breaks;
use crate::units::scale;

/// Face and size of a character.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct St {
    pub face: FaceId,
    pub size: i64,
}

/// The style in force while scanning inline text.
#[derive(Clone, Copy, Debug)]
pub struct StyleState {
    pub family: Family,
    pub bold: bool,
    pub italic: bool,
    pub size: i64,
}

impl StyleState {
    pub fn plain(family: Family, size: i64) -> StyleState {
        StyleState { family, bold: false, italic: false, size }
    }

    pub fn face(&self) -> FaceId {
        FaceId::resolve(self.family, self.bold, self.italic)
    }

    pub fn st(&self) -> St {
        St { face: self.face(), size: self.size }
    }
}

/// A resolved element of the character stream.
#[derive(Clone, Debug)]
pub enum Unit {
    Ch(char, St),
    /// A space; the flag says whether the sentence rule may give it extra
    /// width.
    Space(St, bool),
    /// A rigid space of a given width.
    Rigid(i64),
    /// A footnote reference mark.
    Mark { number: usize, st: St, raise: i64 },
    /// A discretionary hyphenation point.
    Disc,
}

/// Pushes the characters of `s` as ordinary text (spaces become spaces).
pub fn push_text(units: &mut Vec<Unit>, s: &str, st: St) {
    for c in s.chars() {
        if c == ' ' {
            units.push(Unit::Space(st, true));
        } else {
            units.push(Unit::Ch(c, st));
        }
    }
}

/// A footnote found while flattening: its number and text.
pub type NoteRef<'a> = (usize, &'a [Inline]);

/// Flattens inline text into units, applying the style tags. Footnotes are
/// replaced by mark units and collected in `notes`.
pub fn flatten<'a>(env: &Env, inl: &'a [Inline], style: StyleState, units: &mut Vec<Unit>, notes: &mut Vec<NoteRef<'a>>) {
    for node in inl {
        match node {
            Inline::Char(c) => units.push(Unit::Ch(*c, style.st())),
            Inline::Space => units.push(Unit::Space(style.st(), true)),
            Inline::Rigid => {
                let f = env.fonts.face(style.face());
                units.push(Unit::Rigid(scale(f.space, style.size)));
            }
            Inline::Disc => units.push(Unit::Disc),
            Inline::Style(tag, children) => {
                let mut s = style;
                match tag {
                    Tag::Bold => s.bold = true,
                    Tag::Italic => s.italic = true,
                    Tag::Mono => s.family = Family::Mono,
                    Tag::Larger => s.size = style.size * 6 / 5,
                    Tag::Smaller => s.size = style.size * 5 / 6,
                }
                flatten(env, children, s, units, notes);
            }
            Inline::Note(n, content) => {
                let st = St { face: style.face(), size: env.settings.mark_size };
                units.push(Unit::Mark { number: *n, st, raise: env.settings.mark_raise });
                notes.push((*n, content));
            }
        }
    }
}

/// Plain text of inline content: styles dropped, `\-` removed, rigid spaces
/// turned into spaces, runs of spaces collapsed and the ends trimmed.
pub fn plain_text(inl: &[Inline]) -> String {
    fn walk(inl: &[Inline], out: &mut String) {
        for n in inl {
            match n {
                Inline::Char(c) => out.push(*c),
                Inline::Space | Inline::Rigid => out.push(' '),
                Inline::Disc | Inline::Note(..) => {}
                Inline::Style(_, ch) => walk(ch, out),
            }
        }
    }
    let mut raw = String::new();
    walk(inl, &mut raw);
    let mut out = String::new();
    let mut prev_space = false;
    for c in raw.chars() {
        if c == ' ' {
            if !prev_space {
                out.push(' ');
            }
            prev_space = true;
        } else {
            out.push(c);
            prev_space = false;
        }
    }
    out.trim_matches(' ').to_string()
}

/// An item of a horizontal list.
#[derive(Clone, Debug)]
pub enum Item {
    /// A run of glyphs.
    Box(BoxItem),
    /// A rigid box: advances x, emits nothing.
    Rigid(i64),
    Glue { w: i64, y: i64, z: i64, infinite: bool },
    Penalty { p: i64, flagged: bool, pre: Option<BoxItem> },
}

/// A BOX with text.
#[derive(Clone, Debug)]
pub struct BoxItem {
    pub text: String,
    pub face: FaceId,
    pub size: i64,
    pub raise: i64,
    pub width: i64,
    /// Identifies the fragment the box came from (for run merging).
    pub frag: u32,
    /// The footnote number, for a reference mark.
    pub note: Option<usize>,
}

impl Item {
    fn is_box(&self) -> bool {
        matches!(self, Item::Box(_) | Item::Rigid(_))
    }
}

/// Sums over the items of one candidate line.
#[derive(Clone, Copy, Debug, Default)]
pub struct LineSum {
    pub w: i64,
    pub y: i64,
    pub z: i64,
    pub infinite: bool,
    /// Width without the pre-break text of the ending breakpoint.
    pub w_no_pre: i64,
}

/// A horizontal list with prefix sums for O(1) line measurement.
#[derive(Clone, Debug)]
pub struct HList {
    pub items: Vec<Item>,
    /// Item index of each breakpoint; entry 0 is the start of the list.
    pub bps: Vec<usize>,
    first: Vec<usize>,
    pw: Vec<i64>,
    py: Vec<i64>,
    pz: Vec<i64>,
    pinf: Vec<u32>,
}

impl HList {
    pub fn new(items: Vec<Item>) -> HList {
        let n = items.len();
        let mut pw = vec![0; n + 1];
        let mut py = vec![0; n + 1];
        let mut pz = vec![0; n + 1];
        let mut pinf = vec![0; n + 1];
        for (i, it) in items.iter().enumerate() {
            let (w, y, z, inf) = match it {
                Item::Box(b) => (b.width, 0, 0, 0),
                Item::Rigid(w) => (*w, 0, 0, 0),
                Item::Glue { w, y, z, infinite } => (*w, *y, *z, *infinite as u32),
                Item::Penalty { .. } => (0, 0, 0, 0),
            };
            pw[i + 1] = pw[i] + w;
            py[i + 1] = py[i] + y;
            pz[i + 1] = pz[i] + z;
            pinf[i + 1] = pinf[i] + inf;
        }
        let mut bps = vec![0];
        for (i, it) in items.iter().enumerate() {
            let is_bp = match it {
                Item::Glue { .. } => i > 0 && items[i - 1].is_box(),
                Item::Penalty { p, .. } => *p < 10000,
                _ => false,
            };
            if is_bp {
                bps.push(i);
            }
        }
        let first = bps
            .iter()
            .enumerate()
            .map(|(k, &b)| {
                let mut s = if k == 0 { 0 } else { b + 1 };
                while s < n && matches!(items[s], Item::Glue { .. }) {
                    s += 1;
                }
                s
            })
            .collect();
        HList { items, bps, first, pw, py, pz, pinf }
    }

    /// Index of the first item of a line starting after breakpoint `a`
    /// (leading glue skipped).
    pub fn first_item(&self, a: usize) -> usize {
        self.first[a]
    }

    /// Sums for the line from breakpoint number `a` to breakpoint number `b`.
    pub fn line(&self, a: usize, b: usize) -> LineSum {
        let s = self.first[a];
        let e = self.bps[b];
        let mut r = LineSum::default();
        if s < e {
            r.w = self.pw[e] - self.pw[s];
            r.y = self.py[e] - self.py[s];
            r.z = self.pz[e] - self.pz[s];
            r.infinite = self.pinf[e] > self.pinf[s];
        }
        r.w_no_pre = r.w;
        if let Item::Penalty { pre: Some(pre), .. } = &self.items[e] {
            r.w += pre.width;
        }
        r
    }

    /// Natural width of the whole list on one line, ignoring the final
    /// infinite glue and any pre-break text.
    pub fn natural_width(&self) -> i64 {
        self.pw[self.items.len()]
    }

    /// The widest line between consecutive breakpoints.
    pub fn min_width(&self) -> i64 {
        (1..self.bps.len()).map(|b| self.line(b - 1, b).w).max().unwrap_or(0)
    }
}

/// How a list is to be built.
#[derive(Clone, Copy, Debug)]
pub struct BuildOpts {
    /// `align` is not `justify`: glue becomes ragged.
    pub ragged: bool,
    /// The context allows hyphenation.
    pub hyphenate: bool,
}

fn is_skipped_after_sentence(c: char) -> bool {
    matches!(c, ')' | ']' | '}' | '\'' | '"' | '\u{2019}' | '\u{201D}')
}

/// Does the space at `units[i]` follow a sentence end?
fn follows_sentence_end(units: &[Unit], i: usize) -> bool {
    let mut j = i;
    loop {
        if j == 0 {
            return false;
        }
        j -= 1;
        match &units[j] {
            Unit::Disc => continue,
            Unit::Ch(c, _) if is_skipped_after_sentence(*c) => continue,
            _ => break,
        }
    }
    match &units[j] {
        Unit::Ch('.' | '!' | '?', _) => {}
        _ => return false,
    }
    let mut k = j;
    loop {
        if k == 0 {
            return true;
        }
        k -= 1;
        match &units[k] {
            Unit::Disc => continue,
            Unit::Ch(c, _) => return !c.is_ascii_uppercase(),
            _ => return true,
        }
    }
}

/// Builds the horizontal list for `prefix` followed by `body`. Spaces at the
/// very start and end of `body` are dropped; runs of spaces collapse.
pub fn build_list(env: &Env, prefix: Vec<Unit>, mut body: Vec<Unit>, opts: BuildOpts) -> HList {
    while matches!(body.first(), Some(Unit::Space(..))) {
        body.remove(0);
    }
    while matches!(body.last(), Some(Unit::Space(..))) {
        body.pop();
    }
    let mut units = prefix;
    units.append(&mut body);

    let s = &env.settings;
    let mut items: Vec<Item> = Vec::new();
    let mut frag_id: u32 = 0;
    let mut cur: Vec<char> = Vec::new();
    let mut cur_st: Option<St> = None;
    let mut discs: Vec<usize> = Vec::new();

    macro_rules! flush {
        () => {
            if let Some(st) = cur_st.take() {
                frag_id += 1;
                emit_fragment(env, &cur, &discs, st, frag_id, opts.hyphenate, &mut items);
                cur.clear();
                discs.clear();
            }
        };
    }

    let mut i = 0;
    while i < units.len() {
        match &units[i] {
            Unit::Ch(c, st) => {
                if cur_st != Some(*st) {
                    flush!();
                    cur_st = Some(*st);
                }
                cur.push(*c);
            }
            Unit::Disc => {
                if !cur.is_empty() {
                    discs.push(cur.len());
                }
            }
            Unit::Space(st, allow_extra) => {
                flush!();
                let f = env.fonts.face(st.face);
                let extra = *allow_extra && follows_sentence_end(&units, i);
                let (w, mut y, mut z) = if extra {
                    (
                        scale(f.space + f.extra, st.size),
                        scale(f.stretch + f.stretch / 2, st.size),
                        scale(f.shrink, st.size),
                    )
                } else {
                    (scale(f.space, st.size), scale(f.stretch, st.size), scale(f.shrink, st.size))
                };
                if opts.ragged {
                    y = s.ragged_stretch * w;
                    z = 0;
                }
                items.push(Item::Glue { w, y, z, infinite: false });
                while i + 1 < units.len() && matches!(units[i + 1], Unit::Space(..)) {
                    i += 1;
                }
            }
            Unit::Rigid(w) => {
                flush!();
                items.push(Item::Rigid(*w));
            }
            Unit::Mark { number, st, raise } => {
                flush!();
                frag_id += 1;
                let text = number.to_string();
                let width = env.text_width(st.face, &text, st.size);
                items.push(Item::Box(BoxItem {
                    text,
                    face: st.face,
                    size: st.size,
                    raise: *raise,
                    width,
                    frag: frag_id,
                    note: Some(*number),
                }));
            }
        }
        i += 1;
    }
    flush!();
    items.push(Item::Penalty { p: 10000, flagged: false, pre: None });
    items.push(Item::Glue { w: 0, y: 0, z: 0, infinite: true });
    items.push(Item::Penalty { p: -10000, flagged: false, pre: None });
    HList::new(items)
}

fn emit_fragment(env: &Env, chars: &[char], discs: &[usize], st: St, frag: u32, hyphenate: bool, items: &mut Vec<Item>) {
    let n = chars.len();
    let gate = hyphenate
        && env.settings.hyphenate
        && !st.face.is_mono()
        && chars.iter().any(|c| c.is_ascii_alphabetic());
    let breaks = if gate { fragment_breaks(chars, discs, env.patterns()) } else { Vec::new() };
    let face = env.fonts.face(st.face);
    let make = |a: usize, b: usize| {
        let text: String = chars[a..b].iter().collect();
        let width = face.text_width(&text, st.size);
        Item::Box(BoxItem { text, face: st.face, size: st.size, raise: 0, width, frag, note: None })
    };
    let mut prev = 0;
    for b in &breaks {
        items.push(make(prev, b.pos));
        if b.after_hyphen {
            items.push(Item::Penalty { p: env.settings.ex_hyphen_penalty, flagged: true, pre: None });
        } else {
            let Item::Box(pre) = make_hyphen(env, st, frag) else { unreachable!() };
            items.push(Item::Penalty { p: env.settings.hyphen_penalty, flagged: true, pre: Some(pre) });
        }
        prev = b.pos;
    }
    items.push(make(prev, n));
}

fn make_hyphen(env: &Env, st: St, frag: u32) -> Item {
    let width = env.text_width(st.face, "-", st.size);
    Item::Box(BoxItem { text: "-".to_string(), face: st.face, size: st.size, raise: 0, width, frag, note: None })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::Settings;

    fn env() -> Env {
        let dir = std::path::Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/data"));
        Env::load(Settings::default(), dir).unwrap()
    }

    fn list(env: &Env, text: &str) -> HList {
        let mut units = Vec::new();
        let st = StyleState::plain(Family::Serif, 10000).st();
        push_text(&mut units, text, st);
        build_list(env, Vec::new(), units, BuildOpts { ragged: false, hyphenate: true })
    }

    #[test]
    fn words_become_boxes_and_glue() {
        let e = env();
        let l = list(&e, "The quick brown fox.");
        let boxes = l.items.iter().filter(|i| matches!(i, Item::Box(_))).count();
        let glues = l.items.iter().filter(|i| matches!(i, Item::Glue { infinite: false, .. })).count();
        assert_eq!((boxes, glues), (4, 3));
        assert_eq!(l.bps, vec![0, 1, 3, 5, 9]);
        let Item::Box(b) = &l.items[0] else { panic!() };
        assert_eq!(b.width, 15630);
    }

    #[test]
    fn hyphenation_points_become_flagged_penalties() {
        let e = env();
        let l = list(&e, "typesetting");
        let pens: Vec<_> = l.items.iter().filter(|i| matches!(i, Item::Penalty { flagged: true, .. })).collect();
        assert_eq!(pens.len(), 2);
    }

    #[test]
    fn sentence_end_gets_extra_space() {
        let e = env();
        let l = list(&e, "end. next J. Smith");
        let ws: Vec<i64> = l
            .items
            .iter()
            .filter_map(|i| match i {
                Item::Glue { w, infinite: false, .. } => Some(*w),
                _ => None,
            })
            .collect();
        assert_eq!(ws, vec![3660, 2540, 2540]);
    }

    #[test]
    fn leading_and_trailing_spaces_and_runs_collapse() {
        let e = env();
        let l = list(&e, "  a   b  ");
        let glues = l.items.iter().filter(|i| matches!(i, Item::Glue { infinite: false, .. })).count();
        assert_eq!(glues, 1);
    }

    #[test]
    fn plain_text_normalises() {
        let inl = vec![
            Inline::Space,
            Inline::Style(Tag::Bold, vec![Inline::Char('a'), Inline::Disc, Inline::Rigid, Inline::Space, Inline::Char('b')]),
            Inline::Space,
        ];
        assert_eq!(plain_text(&inl), "a b");
    }
}
