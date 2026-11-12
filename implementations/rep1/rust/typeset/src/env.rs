//! The read-only resources shared by every stage of the layout.

use crate::metrics::{FaceId, Fonts};
use crate::patterns::Patterns;
use crate::settings::{PatternSet, Settings};
use std::io;
use std::path::Path;

/// Settings plus the loaded font metrics and hyphenation patterns.
#[derive(Clone, Debug)]
pub struct Env {
    pub settings: Settings,
    pub fonts: Fonts,
    pub english: Patterns,
    pub minimal: Patterns,
}

impl Env {
    /// Loads fonts and patterns from a data directory containing
    /// `faces/*.cfm` and `hyphen/*.chp`.
    pub fn load(settings: Settings, data_dir: &Path) -> io::Result<Env> {
        Ok(Env {
            settings,
            fonts: Fonts::load(&data_dir.join("faces"))?,
            english: Patterns::load(&data_dir.join("hyphen").join("english.chp"))?,
            minimal: Patterns::load(&data_dir.join("hyphen").join("minimal.chp"))?,
        })
    }

    /// The pattern set selected by `hyphen-patterns`.
    pub fn patterns(&self) -> &Patterns {
        match self.settings.hyphen_patterns {
            PatternSet::English => &self.english,
            PatternSet::Minimal => &self.minimal,
        }
    }

    /// Width of a string in a face at a size, as a single box.
    pub fn text_width(&self, face: FaceId, text: &str, size: i64) -> i64 {
        self.fonts.face(face).text_width(text, size)
    }
}
