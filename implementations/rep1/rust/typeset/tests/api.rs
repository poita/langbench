//! Tests of the public library API on small in-memory documents.

use std::path::Path;
use typeset::{typeset as run, Code};

fn data() -> &'static Path {
    Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/data"))
}

const SMALL: &str = "page-width = 200pt\npage-height = 120pt\nmargin-top = 20pt\nmargin-bottom = 20pt\nmargin-left = 20pt\nmargin-right = 20pt\n";

#[test]
fn missing_document_is_reported() {
    let e = run(None, None, data()).unwrap().unwrap_err();
    assert_eq!(e.to_string(), "-:0:0: missing-document");
}

#[test]
fn settings_errors_come_before_document_errors() {
    let e = run(Some("@bogus\n"), Some("widows = x\n"), data()).unwrap().unwrap_err();
    assert_eq!(e.code, Code::BadInteger);
    assert_eq!(e.file, "settings.cfg");
}

#[test]
fn single_line_paragraph_matches_spec_example() {
    let out = run(Some("The quick brown fox.\n"), Some(SMALL), data()).unwrap().unwrap();
    assert!(out.layout.contains("  text body serif 10000 38000 27310 15630 \"The\"\n"));
    assert!(out.layout.contains("  text body serif 10000 108630 27310 15810 \"fox.\"\n"));
    assert!(out.report.contains("total-demerits 100\n"));
    assert!(out.report.contains("lines 1\n"));
}

#[test]
fn empty_document_has_no_pages() {
    let out = run(Some(""), None, data()).unwrap().unwrap();
    assert_eq!(out.layout, "layout 1\npages 0\n");
    assert!(out.report.contains("pages 0\n"));
}

#[test]
fn toc_adds_front_pages_with_roman_labels() {
    let out = run(Some("@toc\n@h1 One\ntext\n"), Some(SMALL), data()).unwrap().unwrap();
    assert!(out.layout.contains("\npage 1 i "));
    assert!(out.layout.contains("\npage 2 1 "));
    assert!(out.report.contains("front-pages 1\n"));
}

#[test]
fn output_is_deterministic() {
    let doc = "@h1 A\nSome text {n|note} here.\n\n@ul\n@li x\n@end\n";
    let a = run(Some(doc), Some(SMALL), data()).unwrap().unwrap();
    let b = run(Some(doc), Some(SMALL), data()).unwrap().unwrap();
    assert_eq!(a.layout, b.layout);
}
