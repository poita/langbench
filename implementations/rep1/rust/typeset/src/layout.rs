//! The block walk: turns the document tree into a flat list of vertical
//! items (lines, glue, rules, table rows, float marks and forced breaks).

use crate::ast::{Block, GroupAttrs, Inline, TableElem};
use crate::env::Env;
use crate::hlist::{build_list, flatten, plain_text, push_text, BuildOpts, StyleState, Unit};
use crate::metrics::{FaceId, Family};
use crate::settings::Align;
use crate::setline::{typeset_list, ListSpec, PlacedLine, Run};
use crate::stats::Stats;
use crate::units::{fdiv, letters, roman, scale};
use crate::vlist::*;

/// The inherited formatting context of a block.
#[derive(Clone, Copy, Debug)]
pub struct Ctx {
    pub family: Family,
    pub size: i64,
    pub leading: i64,
    pub left: i64,
    pub measure: i64,
    pub align: Align,
}

impl Ctx {
    /// The root context of the body.
    pub fn root(env: &Env) -> Ctx {
        let s = &env.settings;
        Ctx {
            family: s.body_font,
            size: s.body_size,
            leading: s.leading,
            left: s.body_x(),
            measure: s.body_width(),
            align: s.align,
        }
    }
}

/// Parameters of one horizontal list of text.
#[derive(Clone, Copy, Debug)]
pub struct TextSpec {
    pub style: StyleState,
    pub leading: i64,
    pub left: i64,
    pub measure: i64,
    pub first_indent: i64,
    pub align: Align,
}

/// The result of walking the document.
#[derive(Debug, Default)]
pub struct Layout {
    pub items: Vec<VItem>,
    pub headings: Vec<HeadingInfo>,
    pub figures: Vec<FigureBlock>,
    /// Lines of each footnote, indexed by number - 1.
    pub notes: Vec<Vec<PlacedLine>>,
}

/// Walks blocks, accumulating vertical items.
pub struct Walker<'a> {
    pub env: &'a Env,
    pub stats: &'a mut Stats,
    pub out: Layout,
    pending_max: i64,
    pending_add: i64,
    started: bool,
    counters: [u64; 4],
}

fn clamp_measure(m: i64) -> i64 {
    m.max(1000)
}

impl<'a> Walker<'a> {
    pub fn new(env: &'a Env, stats: &'a mut Stats) -> Walker<'a> {
        Walker { env, stats, out: Layout::default(), pending_max: 0, pending_add: 0, started: false, counters: [0; 4] }
    }

    /// Walks the whole document body.
    pub fn walk_document(mut self, blocks: &[Block]) -> Layout {
        let ctx = Ctx::root(self.env);
        self.walk_blocks(blocks, &ctx, 0);
        self.out
    }

    // ---- spacing -------------------------------------------------------

    fn enter(&mut self, space: i64) {
        self.pending_max = self.pending_max.max(space);
    }

    /// Emits a leaf block's items with the spacing rules around it.
    pub fn leaf(&mut self, before: i64, after: i64, items: Vec<VItem>) {
        self.pending_max = self.pending_max.max(before);
        if self.started && self.pending_max + self.pending_add > 0 {
            self.out.items.push(VItem::Glue(self.pending_max + self.pending_add));
        }
        self.pending_max = after;
        self.pending_add = 0;
        self.out.items.extend(items);
        self.started = true;
    }

    fn force_break(&mut self) {
        self.out.items.push(VItem::ForceBreak);
        self.pending_max = 0;
        self.pending_add = 0;
    }

    /// Turns the lines of one horizontal list into a group of line items.
    pub fn group(lines: Vec<PlacedLine>, leading: i64, heading: Option<usize>) -> Vec<VItem> {
        let n = lines.len();
        lines
            .into_iter()
            .enumerate()
            .map(|(i, line)| {
                VItem::Line(LineItem { line, leading, k: i + 1, n, heading_group: heading.is_some(), heading })
            })
            .collect()
    }

    // ---- text ----------------------------------------------------------

    /// Builds, breaks and sets one horizontal list of text. Footnotes found
    /// in the text are laid out as a side effect.
    pub fn typeset_text(&mut self, prefix: Vec<Unit>, inl: &[Inline], t: &TextSpec) -> Vec<PlacedLine> {
        let mut units = Vec::new();
        let mut notes = Vec::new();
        flatten(self.env, inl, t.style, &mut units, &mut notes);
        let list = build_list(self.env, prefix, units, BuildOpts { ragged: t.align != Align::Justify, hyphenate: true });
        let spec = ListSpec {
            align: t.align,
            left: t.left,
            measure: t.measure,
            first_indent: t.first_indent,
            face: t.style.face(),
            size: t.style.size,
        };
        let lines = typeset_list(self.env, &list, &spec, self.stats);
        for (n, content) in notes {
            self.footnote(n, content);
        }
        lines
    }

    fn footnote(&mut self, number: usize, content: &[Inline]) {
        let s = &self.env.settings;
        let t = TextSpec {
            style: StyleState::plain(s.footnote_font, s.footnote_size),
            leading: s.footnote_leading,
            left: s.body_x() + s.footnote_indent,
            measure: clamp_measure(s.body_width() - s.footnote_indent),
            first_indent: 0,
            align: s.align,
        };
        self.stats.footnotes += 1;
        let lines = self.typeset_text(Vec::new(), content, &t);
        if self.out.notes.len() < number {
            self.out.notes.resize(number, Vec::new());
        }
        self.out.notes[number - 1] = lines;
    }

    // ---- blocks --------------------------------------------------------

    fn walk_blocks(&mut self, blocks: &[Block], ctx: &Ctx, depth: usize) {
        for b in blocks {
            self.walk_block(b, ctx, depth);
        }
    }

    fn walk_block(&mut self, block: &Block, ctx: &Ctx, depth: usize) {
        let s = &self.env.settings;
        match block {
            Block::Paragraph(inl) => {
                self.stats.paragraphs += 1;
                let t = TextSpec {
                    style: StyleState::plain(ctx.family, ctx.size),
                    leading: ctx.leading,
                    left: ctx.left,
                    measure: ctx.measure,
                    first_indent: s.par_indent,
                    align: ctx.align,
                };
                let lines = self.typeset_text(Vec::new(), inl, &t);
                let items = Self::group(lines, ctx.leading, None);
                self.leaf(s.par_space, s.par_space, items);
            }
            Block::Heading { level, unnumbered, text } => self.heading(*level, *unnumbered, text, ctx),
            Block::Quote(blocks) => {
                self.enter(s.quote_space);
                let c = Ctx {
                    left: ctx.left + s.quote_indent,
                    measure: clamp_measure(ctx.measure - 2 * s.quote_indent),
                    ..*ctx
                };
                self.walk_blocks(blocks, &c, depth);
                self.enter(s.quote_space);
            }
            Block::Group(attrs, blocks) => {
                let c = group_ctx(ctx, attrs);
                self.walk_blocks(blocks, &c, depth);
            }
            Block::List { ordered, start, items } => self.list(*ordered, *start, items, ctx, depth + 1),
            Block::Table { cols, aligns, elems } => self.table(*cols, aligns, elems, ctx),
            Block::Pre(lines) => self.pre(lines, ctx),
            Block::Figure { height, width, caption } => {
                self.stats.figures += 1;
                let fig = self.figure(*height, *width, caption);
                let idx = self.out.figures.len();
                self.out.figures.push(fig);
                self.leaf(0, 0, vec![VItem::FloatMark(idx)]);
            }
            Block::Rule => {
                let item = VItem::Rule { x: ctx.left, width: ctx.measure, thickness: s.rule_thickness };
                self.leaf(s.rule_space, s.rule_space, vec![item]);
            }
            Block::VSpace(h) => self.pending_add += h,
            Block::NewPage => self.force_break(),
        }
    }

    fn heading(&mut self, level: usize, unnumbered: bool, text: &[Inline], ctx: &Ctx) {
        let s = &self.env.settings;
        self.stats.headings += 1;
        let l = level - 1;
        let style = StyleState {
            family: s.heading_font,
            bold: s.heading_bold,
            italic: s.heading_italic,
            size: s.h_size[l],
        };
        let mut prefix = Vec::new();
        let mut number = String::new();
        if !unnumbered && s.heading_number {
            self.counters[l] += 1;
            for c in self.counters.iter_mut().skip(level) {
                *c = 0;
            }
            number = self.counters[..level].iter().map(|c| c.to_string()).collect::<Vec<_>>().join(".");
            push_text(&mut prefix, &number, style.st());
            prefix.push(Unit::Rigid(s.heading_number_gap));
        }
        let idx = self.out.headings.len();
        self.out.headings.push(HeadingInfo { level, unnumbered, number, plain: plain_text(text) });
        let t = TextSpec {
            style,
            leading: s.h_leading[l],
            left: ctx.left,
            measure: ctx.measure,
            first_indent: 0,
            align: s.heading_align,
        };
        let lines = self.typeset_text(prefix, text, &t);
        if level == 1 && s.h1_newpage {
            self.force_break();
        }
        let items = Self::group(lines, s.h_leading[l], Some(idx));
        self.leaf(s.h_space_before[l], s.h_space_after[l], items);
    }

    fn list(&mut self, ordered: bool, start: i64, items: &[crate::ast::ListItem], ctx: &Ctx, depth: usize) {
        let s = &self.env.settings;
        self.enter(s.list_space);
        let lctx = Ctx { left: ctx.left + s.list_indent, measure: clamp_measure(ctx.measure - s.list_indent), ..*ctx };
        for (idx, item) in items.iter().enumerate() {
            if idx > 0 {
                self.enter(s.list_item_space);
            }
            let t = TextSpec {
                style: StyleState::plain(lctx.family, lctx.size),
                leading: lctx.leading,
                left: lctx.left,
                measure: lctx.measure,
                first_indent: 0,
                align: lctx.align,
            };
            let mut lines = self.typeset_text(Vec::new(), &item.text, &t);
            let n = start as u64 + idx as u64;
            let marker = match (ordered, depth % 3) {
                (false, 1) => "\u{2022}".to_string(),
                (false, 2) => "\u{2013}".to_string(),
                (false, _) => "*".to_string(),
                (true, 1) => format!("{n}."),
                (true, 2) => format!("{}.", letters(n)),
                (true, _) => format!("{}.", roman(n)),
            };
            let face = FaceId::resolve(lctx.family, false, false);
            let width = self.env.text_width(face, &marker, lctx.size);
            lines[0].runs.push(Run {
                text: marker,
                face,
                size: lctx.size,
                raise: 0,
                x: lctx.left - s.list_marker_gap - width,
                width,
            });
            let items = Self::group(lines, lctx.leading, None);
            self.leaf(0, 0, items);
            self.walk_blocks(&item.blocks, &lctx, depth);
        }
        self.enter(s.list_space);
    }

    fn pre(&mut self, lines: &[String], ctx: &Ctx) {
        let s = &self.env.settings;
        let face = FaceId::resolve(s.pre_font, false, false);
        let f = self.env.fonts.face(face);
        let left = ctx.left + s.pre_indent;
        let measure = clamp_measure(ctx.measure - s.pre_indent);
        let n = lines.len();
        let mut placed = Vec::new();
        for text in lines {
            let width = f.text_width(text, s.pre_size);
            let runs = if text.is_empty() {
                Vec::new()
            } else {
                vec![Run { text: text.clone(), face, size: s.pre_size, raise: 0, x: left, width }]
            };
            self.stats.lines += 1;
            if width > measure {
                self.stats.overfull_lines += 1;
            }
            placed.push(PlacedLine {
                runs,
                ascent: scale(f.ascent, s.pre_size),
                depth: scale(f.descent, s.pre_size),
                x_end: left + width,
                width,
                notes: Vec::new(),
            });
        }
        let items = (0..n)
            .zip(placed)
            .map(|(i, line)| {
                VItem::Line(LineItem { line, leading: s.pre_leading, k: i + 1, n, heading_group: false, heading: None })
            })
            .collect();
        self.leaf(s.pre_space, s.pre_space, items);
    }

    // ---- tables --------------------------------------------------------

    fn table(&mut self, cols: usize, aligns: &[Align], elems: &[TableElem], ctx: &Ctx) {
        let s = &self.env.settings;
        self.stats.tables += 1;
        let style = StyleState::plain(ctx.family, ctx.size);
        // Build each cell's list once.
        let mut lists: Vec<Option<Vec<crate::hlist::HList>>> = Vec::new();
        let mut nat = vec![0i64; cols];
        let mut min = vec![0i64; cols];
        for e in elems {
            match e {
                TableElem::Row(cells) => {
                    let mut row = Vec::new();
                    for (i, cell) in cells.iter().enumerate() {
                        let mut units = Vec::new();
                        let mut notes = Vec::new();
                        flatten(self.env, cell, style, &mut units, &mut notes);
                        let l = build_list(self.env, Vec::new(), units, BuildOpts { ragged: true, hyphenate: true });
                        nat[i] = nat[i].max(l.natural_width());
                        min[i] = min[i].max(l.min_width());
                        row.push(l);
                    }
                    lists.push(Some(row));
                }
                TableElem::HRule => lists.push(None),
            }
        }
        // Column widths.
        let gap = s.table_col_gap;
        let a = (ctx.measure - (cols as i64 - 1) * gap).max(0);
        let sum_nat: i64 = nat.iter().sum();
        let sum_min: i64 = min.iter().sum();
        let widths: Vec<i64> = if sum_nat <= a {
            nat.clone()
        } else if sum_min >= a {
            min.clone()
        } else {
            let d = sum_nat - a;
            let big_s: i64 = nat.iter().zip(&min).map(|(n, m)| n - m).sum();
            let mut p = 0;
            let mut prev = 0;
            let mut w = Vec::new();
            for i in 0..cols {
                p += nat[i] - min[i];
                let c = fdiv(d * p, big_s);
                w.push(nat[i] - (c - prev));
                prev = c;
            }
            w
        };
        let tw: i64 = widths.iter().sum::<i64>() + (cols as i64 - 1) * gap;
        let mut xs = Vec::new();
        let mut x = ctx.left;
        for w in &widths {
            xs.push(x);
            x += w + gap;
        }

        let face = style.face();
        let mut items = Vec::new();
        let mut prev_row = false;
        let n_elems = elems.len();
        for (ei, row_lists) in lists.iter().enumerate() {
            match row_lists {
                Some(row) => {
                    if prev_row {
                        items.push(VItem::Glue(s.table_row_space));
                    }
                    let mut cells = Vec::new();
                    for (i, l) in row.iter().enumerate() {
                        let spec = ListSpec {
                            align: aligns[i],
                            left: xs[i],
                            measure: widths[i],
                            first_indent: 0,
                            face,
                            size: ctx.size,
                        };
                        cells.push(typeset_list(self.env, l, &spec, self.stats));
                    }
                    let a_row = cells.iter().map(|c| c[0].ascent).max().unwrap_or(0);
                    let n_row = cells.iter().map(|c| c.len()).max().unwrap_or(1) as i64;
                    let d_row = cells.iter().map(|c| c.last().unwrap().depth).max().unwrap_or(0);
                    let height = a_row + (n_row - 1) * s.table_leading + d_row;
                    items.push(VItem::Row(RowItem { height, a_row, leading: s.table_leading, cells }));
                    prev_row = true;
                }
                None => {
                    if ei > 0 {
                        items.push(VItem::Glue(s.table_rule_space));
                    }
                    items.push(VItem::Rule { x: ctx.left, width: tw, thickness: s.table_rule_thickness });
                    if ei + 1 < n_elems {
                        items.push(VItem::Glue(s.table_rule_space));
                    }
                    prev_row = false;
                }
            }
        }
        self.leaf(s.table_space, s.table_space, items);
    }

    // ---- figures -------------------------------------------------------

    fn figure(&mut self, height: i64, width: Option<i64>, caption: &[Inline]) -> FigureBlock {
        let s = &self.env.settings;
        let w = width.unwrap_or(s.figure_width);
        let fw = if w > 0 { w } else { s.body_width() };
        let fx = s.body_x() + fdiv(s.body_width() - fw, 2);
        let style = StyleState::plain(s.figure_caption_font, s.figure_caption_size);
        let st = style.st();
        let mut prefix = Vec::new();
        if !s.figure_caption_prefix.is_empty() {
            push_text(&mut prefix, &s.figure_caption_prefix, st);
            prefix.push(Unit::Space(st, false));
        }
        let number = self.out.figures.len() + 1;
        push_text(&mut prefix, &format!("{number}."), st);
        prefix.push(Unit::Rigid(s.figure_caption_gap));
        let t = TextSpec {
            style,
            leading: s.figure_caption_leading,
            left: fx,
            measure: clamp_measure(fw),
            first_indent: 0,
            align: s.figure_caption_align,
        };
        let lines = self.typeset_text(prefix, caption, &t);
        let mut placed = Vec::new();
        let mut baseline = 0;
        let mut prev_depth = 0;
        for (i, line) in lines.into_iter().enumerate() {
            baseline = if i == 0 {
                height + s.figure_caption_space + line.ascent
            } else {
                baseline + t.leading.max(prev_depth + s.line_skip + line.ascent)
            };
            prev_depth = line.depth;
            placed.push((baseline, line));
        }
        let total = baseline + prev_depth;
        FigureBlock {
            height: total,
            frame: if s.figure_frame { Some((fx, fw, height)) } else { None },
            lines: placed,
        }
    }

    // ---- table of contents ---------------------------------------------

    /// Builds the vertical list of the table of contents.
    pub fn walk_toc(mut self, title: &str, entries: &[TocEntry]) -> Vec<VItem> {
        let s = &self.env.settings;
        let bx = s.body_x();
        let bw = s.body_width();

        let tstyle = StyleState {
            family: s.toc_title_font,
            bold: s.heading_bold,
            italic: s.heading_italic,
            size: s.toc_title_size,
        };
        let mut units = Vec::new();
        push_text(&mut units, title, tstyle.st());
        let list = build_list(
            self.env,
            Vec::new(),
            units,
            BuildOpts { ragged: s.heading_align != Align::Justify, hyphenate: true },
        );
        let spec = ListSpec {
            align: s.heading_align,
            left: bx,
            measure: clamp_measure(bw),
            first_indent: 0,
            face: tstyle.face(),
            size: tstyle.size,
        };
        let lines = typeset_list(self.env, &list, &spec, self.stats);
        let items = Self::group(lines, s.h_leading[0], None);
        self.leaf(0, s.toc_title_space_after, items);

        let style = StyleState::plain(s.toc_font, s.toc_size);
        let face = style.face();
        for e in entries {
            let indent = (e.level as i64 - 1) * s.toc_indent;
            let mut prefix = Vec::new();
            if !e.number.is_empty() {
                push_text(&mut prefix, &e.number, style.st());
                prefix.push(Unit::Rigid(s.toc_number_gap));
            }
            let mut units = Vec::new();
            push_text(&mut units, &e.text, style.st());
            let list = build_list(self.env, prefix, units, BuildOpts { ragged: true, hyphenate: true });
            let spec = ListSpec {
                align: Align::Left,
                left: bx + indent,
                measure: clamp_measure(bw - indent - s.toc_reserve),
                first_indent: 0,
                face,
                size: style.size,
            };
            let mut lines = typeset_list(self.env, &list, &spec, self.stats);
            // Leaders and the page label on the last line.
            let last = lines.last_mut().unwrap();
            let label_w = self.env.text_width(face, &e.page, style.size);
            let label_x = bx + bw - label_w;
            let x_from = last.x_end + s.toc_leader_gap;
            let x_to = label_x - s.toc_leader_gap;
            let unit = self.env.text_width(face, &s.toc_leader, style.size);
            let k = if unit > 0 { fdiv(x_to - x_from, unit).max(0) } else { 0 };
            if k > 0 {
                last.runs.push(Run {
                    text: s.toc_leader.repeat(k as usize),
                    face,
                    size: style.size,
                    raise: 0,
                    x: x_to - k * unit,
                    width: k * unit,
                });
            }
            last.runs.push(Run { text: e.page.clone(), face, size: style.size, raise: 0, x: label_x, width: label_w });
            let items = Self::group(lines, s.toc_leading, None);
            self.leaf(s.toc_entry_space, s.toc_entry_space, items);
        }
        self.out.items
    }
}

/// One table-of-contents entry.
#[derive(Clone, Debug)]
pub struct TocEntry {
    pub level: usize,
    pub number: String,
    pub text: String,
    pub page: String,
}

fn group_ctx(ctx: &Ctx, a: &GroupAttrs) -> Ctx {
    let mut c = *ctx;
    if let Some(v) = a.align {
        c.align = v;
    }
    if let Some(v) = a.size {
        c.size = v;
    }
    if let Some(v) = a.leading {
        c.leading = v;
    }
    if let Some(v) = a.font {
        c.family = v;
    }
    let indent = a.indent.unwrap_or(0);
    let right = a.right_indent.unwrap_or(0);
    c.left += indent;
    c.measure = clamp_measure(c.measure - indent - right);
    c
}
