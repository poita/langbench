//! Pagination: break legality, the per-page cut scan, footnote splitting and
//! the float queue.

use crate::env::Env;
use crate::metrics::FaceId;
use crate::output::{OutItem, OutKind, PageRec, Region};
use crate::setline::PlacedLine;
use crate::units::roman;
use crate::vlist::{FigureBlock, HeadingInfo, VItem};
use std::collections::VecDeque;

/// Whether the pages being produced are body pages or table-of-contents
/// (front) pages.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PageKind {
    Body,
    Front,
}

/// The result of paginating a vertical list.
#[derive(Debug, Default)]
pub struct Pagination {
    pub pages: Vec<PageRec>,
    /// For each heading, the 1-based page on which its first line fell.
    pub heading_pages: Vec<Option<usize>>,
    /// Footnote lines carried between pages, totalled.
    pub split_lines: u64,
}

/// Vertical placement state (see "Vertical placement on a page").
struct Cursor {
    cursor: i64,
    fresh: bool,
    prev_baseline: i64,
    prev_depth: i64,
}

impl Cursor {
    fn new(top: i64) -> Cursor {
        Cursor { cursor: top, fresh: true, prev_baseline: 0, prev_depth: 0 }
    }

    fn line(&mut self, ascent: i64, depth: i64, leading: i64, line_skip: i64) -> i64 {
        let baseline = if self.fresh {
            self.cursor + ascent
        } else {
            self.prev_baseline + leading.max(self.prev_depth + line_skip + ascent)
        };
        self.cursor = baseline + depth;
        self.prev_baseline = baseline;
        self.prev_depth = depth;
        self.fresh = false;
        baseline
    }

    /// Advances over an item, returning the top of a rule/row or the
    /// baseline of a line.
    fn item(&mut self, it: &VItem, line_skip: i64) -> i64 {
        match it {
            VItem::Line(l) => self.line(l.line.ascent, l.line.depth, l.leading, line_skip),
            VItem::Glue(h) => {
                self.cursor += h;
                self.fresh = true;
                0
            }
            VItem::Rule { thickness, .. } => {
                let top = self.cursor;
                self.cursor += thickness;
                self.fresh = true;
                top
            }
            VItem::Row(r) => {
                let top = self.cursor;
                self.cursor += r.height;
                self.fresh = true;
                top
            }
            VItem::FloatMark(_) | VItem::ForceBreak => 0,
        }
    }
}

/// A group of footnote lines: the lines of footnote `note` from line
/// `first_line` on.
#[derive(Clone, Copy, Debug)]
struct FnGroup {
    note: usize,
    first_line: usize,
    /// A split tail carries no mark.
    markless: bool,
}

/// The stack height of footnote groups, built incrementally.
struct FnStack {
    cur: Cursor,
    groups: usize,
    lines: usize,
}

impl FnStack {
    fn new() -> FnStack {
        FnStack { cur: Cursor::new(0), groups: 0, lines: 0 }
    }

    fn start_group(&mut self, item_space: i64) {
        if self.groups > 0 {
            self.cur.cursor += item_space;
        }
        self.groups += 1;
        self.cur.fresh = true;
    }

    fn add_line(&mut self, l: &PlacedLine, leading: i64, line_skip: i64) -> i64 {
        self.lines += 1;
        self.cur.line(l.ascent, l.depth, leading, line_skip)
    }
}

/// Computes which vertical positions are legal page breaks.
fn legality(env: &Env, items: &[VItem]) -> Vec<bool> {
    let s = &env.settings;
    let n = items.len();
    let mut legal = vec![true; n + 1];
    legal[0] = false;
    for (j, it) in items.iter().enumerate() {
        if let VItem::Line(l) = it {
            if l.heading_group {
                if l.k != 1 {
                    legal[j] = false;
                }
            } else if l.k > 1 && !(l.k as i64 > s.orphans && (l.n - l.k + 1) as i64 >= s.widows) {
                legal[j] = false;
            }
        }
    }
    if s.keep_with_next {
        for (j, it) in items.iter().enumerate() {
            if let VItem::Line(l) = it {
                if l.heading_group && l.k == l.n {
                    let mut t = j + 1;
                    while t < n && matches!(items[t], VItem::Glue(_) | VItem::FloatMark(_)) {
                        legal[t] = false;
                        t += 1;
                    }
                    if t < n {
                        legal[t] = false;
                    }
                }
            }
        }
    }
    legal
}

fn push_runs(out: &mut Vec<OutItem>, region: Region, line: &PlacedLine, baseline: i64) {
    for r in &line.runs {
        out.push(OutItem {
            region,
            kind: OutKind::Text {
                face: r.face,
                size: r.size,
                x: r.x,
                y: baseline - r.raise,
                width: r.width,
                text: r.text.clone(),
            },
        });
    }
}

/// Paginates a vertical list.
pub fn paginate(
    env: &Env,
    items: &[VItem],
    figures: &[FigureBlock],
    notes: &[Vec<PlacedLine>],
    headings: &[HeadingInfo],
    kind: PageKind,
) -> Pagination {
    let s = &env.settings;
    let n = items.len();
    let legal = legality(env, items);
    let body_h = s.body_height();
    let mut result = Pagination { heading_pages: vec![None; headings.len()], ..Default::default() };
    let mut queue: VecDeque<usize> = VecDeque::new();
    let mut carry: Vec<FnGroup> = Vec::new();
    let mut i = 0;
    let (mut chapter, mut section) = (String::new(), String::new());
    let fn_face = FaceId::resolve(s.footnote_font, false, false);
    let fn_area = s.footnote_space_before + s.footnote_rule_thickness + s.footnote_space_after;

    let note_lines = |g: &FnGroup| -> &[PlacedLine] { &notes[g.note - 1][g.first_line..] };

    loop {
        // Step 0.
        while i < n && matches!(items[i], VItem::Glue(_) | VItem::ForceBreak) {
            i += 1;
        }
        if i == n && queue.is_empty() && carry.is_empty() {
            break;
        }
        let mut page_items: Vec<OutItem> = Vec::new();

        // Step 1: floats.
        let mut taken: Vec<usize> = Vec::new();
        let mut zone = 0;
        while let Some(&f) = queue.front() {
            let nz = zone + figures[f].height + s.float_space_after;
            let ok = if i < n { body_h - nz >= s.float_min_body } else { taken.is_empty() || nz <= body_h };
            if !ok {
                break;
            }
            queue.pop_front();
            taken.push(f);
            zone = nz;
        }
        let mut y = s.body_y();
        for &f in &taken {
            let fig = &figures[f];
            if let Some((x, w, h)) = fig.frame {
                page_items.push(OutItem { region: Region::Float, kind: OutKind::Box { x, y, width: w, height: h } });
            }
            for (rel, line) in &fig.lines {
                push_runs(&mut page_items, Region::Float, line, y + rel);
            }
            y += fig.height + s.float_space_after;
        }
        let body_top = s.body_y() + zone;
        let goal = body_h - zone;

        // Step 2/3: choose the cut.
        let cut = if i < n {
            let mut cur = Cursor::new(body_top);
            let mut used_cursor = body_top;
            let mut stack = FnStack::new();
            for g in &carry {
                stack.start_group(s.footnote_item_space);
                for l in note_lines(g) {
                    stack.add_line(l, s.footnote_leading, s.line_skip);
                }
            }
            let mut best: Option<usize> = None;
            let mut forced: Option<usize> = None;
            let mut j = i + 1;
            loop {
                let item = &items[j - 1];
                if matches!(item, VItem::ForceBreak) {
                    forced = Some(j - 1);
                    break;
                }
                cur.item(item, s.line_skip);
                if !matches!(item, VItem::Glue(_)) {
                    used_cursor = cur.cursor;
                }
                if let VItem::Line(l) = item {
                    for &nn in &l.line.notes {
                        stack.start_group(s.footnote_item_space);
                        for fl in &notes[nn - 1] {
                            stack.add_line(fl, s.footnote_leading, s.line_skip);
                        }
                    }
                }
                let a_fn = if stack.lines > 0 { fn_area + stack.cur.cursor } else { 0 };
                let used = (used_cursor - body_top) + a_fn.min(s.footnote_max_height);
                if used <= goal && legal[j] {
                    best = Some(j);
                }
                if used > goal || j == n {
                    break;
                }
                j += 1;
            }
            match (forced, best) {
                (Some(f), _) => f,
                (None, Some(b)) => b,
                (None, None) => (i + 1..=n).find(|&j| legal[j]).unwrap_or(n),
            }
        } else {
            n
        };

        // Step 4: place the body.
        let mut end = cut;
        while end > i && matches!(items[end - 1], VItem::Glue(_)) {
            end -= 1;
        }
        let body_empty = end == i;
        let mut cur = Cursor::new(body_top);
        let mut referenced: Vec<usize> = Vec::new();
        let page_number = result.pages.iter().filter(|p| !p.front).count() + 1;
        for (idx, it) in items.iter().enumerate().take(end).skip(i) {
            let _ = idx;
            let top_or_baseline = cur.item(it, s.line_skip);
            match it {
                VItem::Line(l) => {
                    push_runs(&mut page_items, Region::Body, &l.line, top_or_baseline);
                    referenced.extend(l.line.notes.iter().copied());
                    if let (Some(h), 1) = (l.heading, l.k) {
                        result.heading_pages[h] = Some(page_number);
                        let hi = &headings[h];
                        let text = if hi.number.is_empty() { hi.plain.clone() } else { format!("{} {}", hi.number, hi.plain) };
                        match hi.level {
                            1 => chapter = text,
                            2 => section = text,
                            _ => {}
                        }
                    }
                }
                VItem::Rule { x, width, thickness } => page_items.push(OutItem {
                    region: Region::Body,
                    kind: OutKind::Rule { x: *x, y: top_or_baseline, width: *width, thickness: *thickness },
                }),
                VItem::Row(r) => {
                    for cell in &r.cells {
                        for (k, line) in cell.iter().enumerate() {
                            let base = top_or_baseline + r.a_row + k as i64 * r.leading;
                            push_runs(&mut page_items, Region::Body, line, base);
                        }
                    }
                }
                _ => {}
            }
        }
        let used_b = if body_empty { 0 } else { cur.cursor - body_top };

        // Step 5: footnotes.
        let mut groups: Vec<FnGroup> = std::mem::take(&mut carry);
        for nn in referenced {
            groups.push(FnGroup { note: nn, first_line: 0, markless: false });
        }
        if !groups.is_empty() {
            let avail = goal - used_b - fn_area;
            // Cumulative heights and relative baselines over all candidate lines.
            let mut stack = FnStack::new();
            let mut cum: Vec<i64> = Vec::new();
            let mut base_rel: Vec<i64> = Vec::new();
            let mut start_of: Vec<usize> = Vec::new();
            for g in &groups {
                stack.start_group(s.footnote_item_space);
                start_of.push(cum.len());
                for l in note_lines(g) {
                    let b = stack.add_line(l, s.footnote_leading, s.line_skip);
                    base_rel.push(b);
                    cum.push(stack.cur.cursor);
                }
            }
            let total = cum.len();
            let mut t = cum.iter().take_while(|&&h| h <= avail).count();
            // Find the group containing the boundary.
            let group_of = |t: usize| -> usize { start_of.iter().rposition(|&st| st < t).unwrap_or(0) };
            if t > 0 && t < total {
                let gi = group_of(t);
                let gend = start_of.get(gi + 1).copied().unwrap_or(total);
                if t < gend {
                    let placed = t - start_of[gi];
                    if (placed as i64) < s.footnote_min_split && start_of[gi] > 0 {
                        t = start_of[gi];
                    }
                }
            }
            if body_empty && t == 0 && total > 0 {
                t = 1;
            }
            // Carry the rest.
            let mut new_carry = Vec::new();
            for (gi, g) in groups.iter().enumerate() {
                let gstart = start_of[gi];
                let gend = start_of.get(gi + 1).copied().unwrap_or(total);
                if gend <= t {
                    continue;
                }
                if gstart < t {
                    new_carry.push(FnGroup { note: g.note, first_line: g.first_line + (t - gstart), markless: true });
                } else {
                    new_carry.push(*g);
                }
            }
            result.split_lines += (total - t) as u64;
            carry = new_carry;

            if t > 0 {
                let h_fn = cum[t - 1];
                let rule_top = s.body_bottom() - h_fn - s.footnote_space_after - s.footnote_rule_thickness;
                let stack_top = rule_top + s.footnote_rule_thickness + s.footnote_space_after;
                page_items.push(OutItem {
                    region: Region::Footnote,
                    kind: OutKind::Rule {
                        x: s.body_x(),
                        y: rule_top,
                        width: s.footnote_rule_width,
                        thickness: s.footnote_rule_thickness,
                    },
                });
                for (gi, g) in groups.iter().enumerate() {
                    let gstart = start_of[gi];
                    if gstart >= t {
                        break;
                    }
                    let gend = start_of.get(gi + 1).copied().unwrap_or(total).min(t);
                    for (off, line) in note_lines(g).iter().enumerate().take(gend - gstart) {
                        let baseline = stack_top + base_rel[gstart + off];
                        push_runs(&mut page_items, Region::Footnote, line, baseline);
                        if off == 0 && !g.markless && g.first_line == 0 {
                            let text = g.note.to_string();
                            let w = env.text_width(fn_face, &text, s.footnote_mark_size);
                            page_items.push(OutItem::text(
                                Region::Footnote,
                                fn_face,
                                s.footnote_mark_size,
                                s.body_x() + s.footnote_indent - s.footnote_mark_gap - w,
                                baseline - s.footnote_mark_raise,
                                w,
                                &text,
                            ));
                        }
                    }
                }
            }
        }

        // Step 6: queue floats.
        for it in &items[i..cut] {
            if let VItem::FloatMark(f) = it {
                queue.push_back(*f);
            }
        }

        let m = result.pages.len() + 1;
        let (label, value, front) = match kind {
            PageKind::Body => {
                let v = s.page_start + page_number as i64 - 1;
                (v.to_string(), v, false)
            }
            PageKind::Front => (roman(m as u64), m as i64, true),
        };
        result.pages.push(PageRec {
            items: page_items,
            label,
            label_value: value,
            front,
            chapter: chapter.clone(),
            section: section.clone(),
        });
        i = cut;
    }
    result
}
