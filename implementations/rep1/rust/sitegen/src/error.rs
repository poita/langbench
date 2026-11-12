//! The error type of the site generator.

use std::fmt;
use std::io;
use std::path::PathBuf;

use crate::template;

/// Anything that can go wrong while building a site.
#[derive(Debug)]
pub enum Error {
    /// A file or directory could not be read or written.
    Io {
        /// The path involved.
        path: PathBuf,
        /// The underlying error.
        source: io::Error,
    },
    /// A TOML-subset document is malformed.
    Toml {
        /// The file (or description) of the document.
        file: String,
        /// 1-based line number.
        line: usize,
        /// What is wrong.
        message: String,
    },
    /// A site file is well-formed TOML but does not have the required shape.
    Content {
        /// The file concerned.
        file: String,
        /// What is wrong.
        message: String,
    },
    /// A template failed to load or render.
    Template {
        /// The entry-point template.
        template: String,
        /// The page being rendered.
        page: String,
        /// The template error.
        source: template::Error,
    },
}

impl Error {
    pub(crate) fn io(path: impl Into<PathBuf>, source: io::Error) -> Error {
        Error::Io {
            path: path.into(),
            source,
        }
    }

    pub(crate) fn content(file: impl Into<String>, message: impl Into<String>) -> Error {
        Error::Content {
            file: file.into(),
            message: message.into(),
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Io { path, source } => write!(f, "{}: {}", path.display(), source),
            Error::Toml {
                file,
                line,
                message,
            } => write!(f, "{}:{}: {}", file, line, message),
            Error::Content { file, message } => write!(f, "{}: {}", file, message),
            Error::Template {
                template,
                page,
                source,
            } => write!(f, "rendering {} with {}: {}", page, template, source),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Io { source, .. } => Some(source),
            Error::Template { source, .. } => Some(source),
            _ => None,
        }
    }
}

/// A specialised `Result` for site generation.
pub type Result<T> = std::result::Result<T, Error>;
