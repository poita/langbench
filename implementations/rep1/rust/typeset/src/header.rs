//! Running headers and footers.

use crate::ast::Meta;
use crate::env::Env;
use crate::hlist::{build_list, push_text, BuildOpts, Item, StyleState};
use crate::output::{OutItem, PageRec, Region};
use crate::settings::{Placeholder, Template, TextPart};
use crate::units::fdiv;

/// Document-wide values available to placeholders.
pub struct HeaderContext<'a> {
    pub meta: &'a Meta,
    /// Number of body pages.
    pub body_pages: usize,
}

fn substitute(t: &Template, page: &PageRec, ctx: &HeaderContext) -> String {
    let mut out = String::new();
    for part in &t.0 {
        match part {
            TextPart::Lit(s) => out.push_str(s),
            TextPart::Ph(p) => match p {
                Placeholder::Page => out.push_str(&page.label),
                Placeholder::Pages => out.push_str(&ctx.body_pages.to_string()),
                Placeholder::Title => out.push_str(&ctx.meta.title),
                Placeholder::Author => out.push_str(&ctx.meta.author),
                Placeholder::Date => out.push_str(&ctx.meta.date),
                Placeholder::Chapter => out.push_str(&page.chapter),
                Placeholder::Section => out.push_str(&page.section),
            },
        }
    }
    out
}

/// Renders the six header/footer slots of a page into output items.
pub fn render(env: &Env, page: &PageRec, ctx: &HeaderContext) -> Vec<OutItem> {
    let s = &env.settings;
    let style = StyleState::plain(s.header_font, s.header_size);
    let st = style.st();
    let even = page.label_value % 2 == 0;
    let mut out = Vec::new();
    for slot in 0..6 {
        let template = if even { &s.slots.even[slot] } else { &s.slots.plain[slot] };
        let text = substitute(template, page, ctx);
        let mut units = Vec::new();
        push_text(&mut units, &text, st);
        let list = build_list(env, Vec::new(), units, BuildOpts { ragged: false, hyphenate: false });
        let w = list.natural_width();
        let has_box = list.items.iter().any(|i| matches!(i, Item::Box(_)));
        if !has_box {
            continue;
        }
        let x0 = match slot % 3 {
            0 => s.body_x(),
            1 => s.body_x() + fdiv(s.body_width() - w, 2),
            _ => s.body_x() + s.body_width() - w,
        };
        let (region, baseline) =
            if slot < 3 { (Region::Header, s.header_baseline) } else { (Region::Footer, s.footer_baseline) };
        let mut x = x0;
        for it in &list.items {
            match it {
                Item::Box(b) => {
                    out.push(OutItem::text(region, b.face, b.size, x, baseline, b.width, &b.text));
                    x += b.width;
                }
                Item::Glue { w, .. } => x += w,
                Item::Rigid(w) => x += w,
                Item::Penalty { .. } => {}
            }
        }
    }
    out
}
