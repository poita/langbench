//! Vertical items: what the block walk produces and the paginator consumes.

use crate::setline::PlacedLine;

/// One line of a vertical list with its group identity.
#[derive(Clone, Debug)]
pub struct LineItem {
    pub line: PlacedLine,
    /// Leading of the horizontal list the line came from.
    pub leading: i64,
    /// 1-based index of the line in its group.
    pub k: usize,
    /// Number of lines in the group.
    pub n: usize,
    /// `true` when the group is a heading.
    pub heading_group: bool,
    /// Index into the heading table, for lines of headings.
    pub heading: Option<usize>,
}

/// A table row: cell lines are placed relative to the row's top.
#[derive(Clone, Debug)]
pub struct RowItem {
    pub height: i64,
    /// Largest first-line ascent in the row.
    pub a_row: i64,
    pub leading: i64,
    pub cells: Vec<Vec<PlacedLine>>,
}

/// A vertical item.
#[derive(Clone, Debug)]
pub enum VItem {
    Line(LineItem),
    Glue(i64),
    Rule { x: i64, width: i64, thickness: i64 },
    Row(RowItem),
    FloatMark(usize),
    ForceBreak,
}

/// What the table of contents and running headers need to know about a
/// heading.
#[derive(Clone, Debug)]
pub struct HeadingInfo {
    pub level: usize,
    pub unnumbered: bool,
    /// Empty when the heading is unnumbered.
    pub number: String,
    pub plain: String,
}

/// A laid-out figure, positioned relative to its top.
#[derive(Clone, Debug)]
pub struct FigureBlock {
    pub height: i64,
    /// `(x, width, height)` of the frame, when frames are on.
    pub frame: Option<(i64, i64, i64)>,
    /// Caption lines with their baselines relative to the block's top.
    pub lines: Vec<(i64, PlacedLine)>,
}
