//! Error type for the library.

use crate::xml::XmlError;
use std::fmt;

/// Everything that can go wrong while rendering a document or a job list.
#[derive(Debug)]
pub enum Error {
    /// The SVG file is not parseable XML.
    Xml(XmlError),
    /// The document element is not `<svg>`.
    NotSvg(String),
    /// A line of `render.txt` is malformed.
    BadJobLine {
        /// 1-based line number.
        line: usize,
        /// What is wrong with it.
        reason: String,
    },
    /// An I/O failure, with context.
    Io(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Xml(e) => write!(f, "XML error: {e}"),
            Error::NotSvg(tag) => write!(f, "document element is <{tag}>, expected <svg>"),
            Error::BadJobLine { line, reason } => write!(f, "render.txt line {line}: {reason}"),
            Error::Io(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<XmlError> for Error {
    fn from(e: XmlError) -> Self {
        Error::Xml(e)
    }
}
