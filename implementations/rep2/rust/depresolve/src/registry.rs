//! The package registry: interned package names, versions sorted newest
//! first, and requirements compiled to index ranges.

use std::collections::HashMap;

use crate::version::{Interval, Version};

/// Dense identifier of a package inside one [`Registry`].
pub type PackageId = u32;

/// A requirement on a package, compiled against the registry.
///
/// The versions of every package are stored newest first, so the versions that
/// satisfy a range form the contiguous index range `lo..hi` of
/// [`Registry::versions`] for the target package.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Requirement {
    /// The required package.
    pub package: PackageId,
    /// First satisfying index (newest satisfying version).
    pub lo: u32,
    /// One past the last satisfying index.
    pub hi: u32,
}

impl Requirement {
    /// Whether the version at newest-first index `index` satisfies this
    /// requirement.
    #[inline]
    pub fn admits(&self, index: u32) -> bool {
        self.lo <= index && index < self.hi
    }
}

/// An immutable registry produced by [`RegistryBuilder::build`].
#[derive(Debug, Default)]
pub struct Registry {
    names: Vec<String>,
    ids: HashMap<String, PackageId>,
    /// Per package: versions, newest first.
    versions: Vec<Vec<Version>>,
    /// Per package, per version (same order): requirements in written order.
    requirements: Vec<Vec<Vec<Requirement>>>,
}

impl Registry {
    /// Number of distinct package names (including names that are only ever
    /// mentioned in requirements).
    pub fn package_count(&self) -> usize {
        self.names.len()
    }

    /// Looks up a package by name.
    pub fn id_of(&self, name: &str) -> Option<PackageId> {
        self.ids.get(name).copied()
    }

    /// The name of a package.
    pub fn name(&self, id: PackageId) -> &str {
        &self.names[id as usize]
    }

    /// All versions of a package, newest first.
    pub fn versions(&self, id: PackageId) -> &[Version] {
        &self.versions[id as usize]
    }

    /// The requirements of the version at newest-first index `index` of
    /// package `id`, in the order written.
    pub fn requirements(&self, id: PackageId, index: u32) -> &[Requirement] {
        &self.requirements[id as usize][index as usize]
    }
}

/// A requirement as written: target package and range, not yet compiled.
struct RawRequirement {
    package: PackageId,
    range: Interval,
}

/// Incrementally collects registry lines, then compiles them with
/// [`build`](RegistryBuilder::build).
#[derive(Default)]
pub struct RegistryBuilder {
    names: Vec<String>,
    ids: HashMap<String, PackageId>,
    entries: Vec<Vec<(Version, Vec<RawRequirement>)>>,
    root: Vec<RawRequirement>,
}

impl RegistryBuilder {
    /// Creates an empty builder.
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns the id for `name`, creating the package if needed.
    pub fn intern(&mut self, name: &str) -> PackageId {
        if let Some(&id) = self.ids.get(name) {
            return id;
        }
        let id = self.names.len() as PackageId;
        self.names.push(name.to_owned());
        self.ids.insert(name.to_owned(), id);
        self.entries.push(Vec::new());
        id
    }

    /// Declares a package version with its `(package name, range)`
    /// requirements, in the order written.
    pub fn add_version(&mut self, name: &str, version: Version, requirements: &[(&str, Interval)]) {
        let id = self.intern(name);
        let raw = self.raw(requirements);
        self.entries[id as usize].push((version, raw));
    }

    fn raw(&mut self, requirements: &[(&str, Interval)]) -> Vec<RawRequirement> {
        requirements
            .iter()
            .map(|&(n, range)| RawRequirement { package: self.intern(n), range })
            .collect()
    }

    /// Sets the root manifest's requirements, in the order written.
    pub fn set_root(&mut self, requirements: &[(&str, Interval)]) {
        self.root = self.raw(requirements);
    }

    /// Sorts every package's versions newest first and compiles all ranges to
    /// index ranges.
    pub fn build(self) -> Problem {
        let RegistryBuilder { names, ids, mut entries, root } = self;
        for e in entries.iter_mut() {
            e.sort_unstable_by(|a, b| b.0.cmp(&a.0));
        }
        let versions: Vec<Vec<Version>> =
            entries.iter().map(|e| e.iter().map(|(v, _)| *v).collect()).collect();
        let compile = |raw: &RawRequirement| -> Requirement {
            let vs = &versions[raw.package as usize];
            let r = raw.range;
            // `vs` is descending: versions >= hi form a prefix, versions >= lo
            // a longer prefix.
            let lo = match r.hi {
                Some(hi) => vs.partition_point(|v| *v >= hi),
                None => 0,
            };
            let hi = vs.partition_point(|v| *v >= r.lo);
            let (lo, hi) = if r.is_empty() || lo > hi { (0, 0) } else { (lo, hi) };
            Requirement { package: raw.package, lo: lo as u32, hi: hi as u32 }
        };
        let requirements = entries
            .iter()
            .map(|e| e.iter().map(|(_, reqs)| reqs.iter().map(&compile).collect()).collect())
            .collect();
        let root = root.iter().map(&compile).collect();
        Problem { registry: Registry { names, ids, versions, requirements }, root }
    }
}

/// A registry together with the root manifest to resolve against it.
#[derive(Debug)]
pub struct Problem {
    /// The package registry.
    pub registry: Registry,
    /// Requirements of the root manifest, in the order written.
    pub root: Vec<Requirement>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compiles_ranges_to_index_ranges() {
        let mut b = RegistryBuilder::new();
        for v in ["1.1.0", "1.3.0", "1.2.5", "2.0.0"] {
            b.add_version("c", v.parse().unwrap(), &[]);
        }
        b.set_root(&[
            ("c", "~1.2.0".parse().unwrap()),
            ("c", "^1.0.0".parse().unwrap()),
            ("c", "*".parse().unwrap()),
            ("c", ">=3.0.0".parse().unwrap()),
            ("c", ">=2.0.0 <1.0.0".parse().unwrap()),
            ("zzz", "*".parse().unwrap()),
        ]);
        let Problem { registry: reg, root } = b.build();
        let c = reg.id_of("c").unwrap();
        let vs: Vec<String> = reg.versions(c).iter().map(|v| v.to_string()).collect();
        assert_eq!(vs, ["2.0.0", "1.3.0", "1.2.5", "1.1.0"]);
        let span = |r: &Requirement| (r.lo, r.hi);
        assert_eq!(span(&root[0]), (2, 3));
        assert_eq!(span(&root[1]), (1, 4));
        assert_eq!(span(&root[2]), (0, 4));
        assert_eq!(span(&root[3]), (0, 0));
        assert_eq!(span(&root[4]), (0, 0));
        assert_eq!(span(&root[5]), (0, 0));
        assert!(root[0].admits(2) && !root[0].admits(1));
    }
}
