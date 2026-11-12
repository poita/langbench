//! The package registry and requirement types.

use crate::range::Range;
use crate::version::Version;
use std::collections::HashMap;

/// A dependency requirement: a package name and an acceptable version range.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Requirement {
    /// Name of the required package.
    pub name: String,
    /// Versions of that package that are acceptable.
    pub range: Range,
}

impl Requirement {
    /// Creates a requirement.
    pub fn new(name: impl Into<String>, range: Range) -> Self {
        Requirement {
            name: name.into(),
            range,
        }
    }
}

/// One published version of a package together with its requirements.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    /// The version number.
    pub version: Version,
    /// Requirements, in the order they are listed (the order drives the search).
    pub requirements: Vec<Requirement>,
}

/// A collection of packages, each with any number of releases.
#[derive(Debug, Clone, Default)]
pub struct Registry {
    packages: HashMap<String, Vec<Release>>,
}

impl Registry {
    /// Creates an empty registry.
    pub fn new() -> Self {
        Registry::default()
    }

    /// Adds a release. Releases of one package may be added in any order.
    pub fn add(
        &mut self,
        name: impl Into<String>,
        version: Version,
        requirements: Vec<Requirement>,
    ) {
        self.packages.entry(name.into()).or_default().push(Release {
            version,
            requirements,
        });
    }

    /// The releases of `name` in insertion order (empty if unknown).
    pub fn releases(&self, name: &str) -> &[Release] {
        self.packages.get(name).map_or(&[], Vec::as_slice)
    }

    /// Number of distinct packages that have at least one release.
    pub fn package_count(&self) -> usize {
        self.packages.len()
    }

    pub(crate) fn packages(&self) -> impl Iterator<Item = (&String, &Vec<Release>)> {
        self.packages.iter()
    }
}
