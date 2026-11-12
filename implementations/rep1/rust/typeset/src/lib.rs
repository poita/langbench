//! # typeset
//!
//! A typesetting engine for *Codexa*, an invented markup language. Given a
//! document and optional settings it lays the text out on numbered pages with
//! total-fit (Knuth–Plass) line breaking, Liang hyphenation, footnotes,
//! floating figures, tables, a generated table of contents and running
//! headers, and describes every placed item in a plain-text `layout.txt`.
//!
//! Everything is exact integer arithmetic (lengths are millipoints), so the
//! output is byte-for-byte reproducible.
//!
//! ## Using the library
//!
//! ```no_run
//! use std::path::Path;
//!
//! let document = "@h1 Hello\nThe quick brown fox.\n";
//! match typeset::typeset(Some(document), None, Path::new("data")).unwrap() {
//!     Ok(out) => {
//!         println!("{}", out.layout);
//!         println!("{}", out.report);
//!     }
//!     Err(e) => println!("invalid input: {e}"),
//! }
//! ```
//!
//! ## Module map
//!
//! * [`settings`], [`parser`], [`inline`], [`ast`]: reading the inputs
//! * [`metrics`], [`patterns`]: font metrics and hyphenation data
//! * [`hlist`], [`linebreak`], [`setline`]: horizontal lists, line breaking
//!   and line setting
//! * [`layout`], [`vlist`]: the block walk producing vertical items
//! * [`page`], [`header`]: pagination, running headers and footers
//! * [`output`]: `layout.txt` and `report.txt`

pub mod ast;
pub mod env;
pub mod error;
pub mod header;
pub mod hlist;
pub mod inline;
pub mod layout;
pub mod linebreak;
pub mod metrics;
pub mod output;
pub mod page;
pub mod parser;
pub mod patterns;
pub mod settings;
pub mod setline;
pub mod stats;
pub mod units;
pub mod values;
pub mod vlist;

use std::fs;
use std::io;
use std::path::Path;

pub use error::{Code, Error};
pub use stats::Stats;

/// The two files produced for a valid document.
#[derive(Clone, Debug)]
pub struct Output {
    /// Contents of `layout.txt`.
    pub layout: String,
    /// Contents of `report.txt`.
    pub report: String,
}

/// Typesets a document.
///
/// `document` is the text of `document.cdx` (`None` if the file is missing),
/// `settings` the text of `settings.cfg` if present, and `data_dir` the
/// directory holding `faces/*.cfm` and `hyphen/*.chp`.
///
/// The outer `Result` reports problems reading the data files; the inner one
/// is the specification's *invalid document* outcome, with the position of
/// the first error.
pub fn typeset(document: Option<&str>, settings: Option<&str>, data_dir: &Path) -> io::Result<Result<Output, Error>> {
    let Some(document) = document else {
        return Ok(Err(Error::new("-", 0, 0, Code::MissingDocument)));
    };
    let parsed_settings = match settings::Settings::parse(settings) {
        Ok(s) => s,
        Err(e) => return Ok(Err(e)),
    };
    let doc = match parser::parse_document(document) {
        Ok(d) => d,
        Err(e) => return Ok(Err(e)),
    };
    let env = env::Env::load(parsed_settings, data_dir)?;
    Ok(Ok(layout_document(&env, &doc)))
}

/// Lays out an already parsed document.
pub fn layout_document(env: &env::Env, doc: &ast::Document) -> Output {
    let s = &env.settings;
    let mut stats = Stats::default();

    // Body.
    let lay = layout::Walker::new(env, &mut stats).walk_document(&doc.blocks);
    let body = page::paginate(env, &lay.items, &lay.figures, &lay.notes, &lay.headings, page::PageKind::Body);
    stats.footnote_split_lines += body.split_lines;

    // Table of contents.
    let mut front = Vec::new();
    if let Some(toc) = &doc.toc {
        let entries: Vec<layout::TocEntry> = lay
            .headings
            .iter()
            .enumerate()
            .filter(|(_, h)| !h.unnumbered && h.level as i64 <= s.toc_depth)
            .map(|(i, h)| layout::TocEntry {
                level: h.level,
                number: h.number.clone(),
                text: h.plain.clone(),
                page: (s.page_start + body.heading_pages[i].unwrap_or(1) as i64 - 1).to_string(),
            })
            .collect();
        let title = toc.title.clone().unwrap_or_else(|| s.toc_title.clone());
        let items = layout::Walker::new(env, &mut stats).walk_toc(&title, &entries);
        front = page::paginate(env, &items, &[], &[], &[], page::PageKind::Front).pages;
    }

    // Headers and footers, then output.
    let front_pages = front.len();
    let body_pages = body.pages.len();
    let hctx = header::HeaderContext { meta: &doc.meta, body_pages };
    let mut pages = front;
    pages.extend(body.pages);
    for p in pages.iter_mut() {
        let extra = header::render(env, p, &hctx);
        p.items.extend(extra);
    }
    let geometry = output::PageGeometry {
        width: s.page_width,
        height: s.page_height,
        body_x: s.body_x(),
        body_y: s.body_y(),
        body_width: s.body_width(),
        body_height: s.body_height(),
    };
    Output {
        layout: output::format_layout(&pages, &geometry),
        report: output::format_report(&stats, pages.len(), front_pages),
    }
}

/// Runs the command-line contract: reads `document.cdx` and the optional
/// `settings.cfg` from `input`, and writes either `layout.txt` and
/// `report.txt` or a single `error.txt` into `output`.
pub fn run_dir(input: &Path, output: &Path, data_dir: &Path) -> io::Result<()> {
    let read = |name: &str| -> io::Result<Option<String>> {
        match fs::read_to_string(input.join(name)) {
            Ok(s) => Ok(Some(s)),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
        }
    };
    let document = read("document.cdx")?;
    let settings = read("settings.cfg")?;
    fs::create_dir_all(output)?;
    match typeset(document.as_deref(), settings.as_deref(), data_dir)? {
        Ok(out) => {
            fs::write(output.join("layout.txt"), out.layout)?;
            fs::write(output.join("report.txt"), out.report)?;
        }
        Err(e) => fs::write(output.join("error.txt"), format!("{e}\n"))?,
    }
    Ok(())
}
