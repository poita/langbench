//! The counters reported in `report.txt`.

/// Document-wide counters.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    pub lines: u64,
    pub paragraphs: u64,
    pub headings: u64,
    pub tables: u64,
    pub figures: u64,
    pub footnotes: u64,
    pub footnote_split_lines: u64,
    pub hyphenated_lines: u64,
    pub overfull_lines: u64,
    pub emergency_lists: u64,
    pub total_demerits: i64,
}
