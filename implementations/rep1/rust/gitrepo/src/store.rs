//! The object database: loose objects and packfiles.
//!
//! An [`ObjectStore`] reads the pack indexes, the packs and the list of loose
//! objects once, when it is opened. Objects are then looked up by id (a loose
//! copy wins over a packed one) and cached for the lifetime of the store,
//! including every delta base met on the way.

use std::cell::RefCell;
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::rc::Rc;

use crate::delta::apply_delta;
use crate::error::{Error, Result};
use crate::inflate::zlib_decompress;
use crate::object::{Kind, Object};
use crate::oid::ObjectId;
use crate::pack::{Pack, PackEntry, PackIndex};

/// Deepest delta chain followed before the object is declared damaged.
/// (Git's default maximum depth is 50; this only guards against cycles.)
const MAX_DELTA_DEPTH: u32 = 512;

/// Read access to an object database (`objects/` of a repository).
pub struct ObjectStore {
    objects_dir: std::path::PathBuf,
    /// Sorted ids of all loose object files (including damaged ones).
    loose: Vec<ObjectId>,
    /// Usable packs, ordered by file name.
    packs: Vec<Pack>,
    cache: RefCell<HashMap<ObjectId, Rc<Object>>>,
    pack_cache: RefCell<HashMap<(usize, u64), Rc<Object>>>,
}

fn is_lower_hex(s: &[u8]) -> bool {
    s.iter().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

impl ObjectStore {
    /// Opens the object directory. Missing directories are treated as empty;
    /// packs whose index or pack file is unusable are ignored.
    pub fn open(objects_dir: &Path) -> ObjectStore {
        let mut store = ObjectStore {
            objects_dir: objects_dir.to_path_buf(),
            loose: Vec::new(),
            packs: Vec::new(),
            cache: RefCell::new(HashMap::new()),
            pack_cache: RefCell::new(HashMap::new()),
        };
        store.scan_loose();
        store.scan_packs();
        store
    }

    fn scan_loose(&mut self) {
        let Ok(dirs) = fs::read_dir(&self.objects_dir) else { return };
        for dir in dirs.flatten() {
            let name = dir.file_name();
            let Some(prefix) = name.to_str() else { continue };
            if prefix.len() != 2 || !is_lower_hex(prefix.as_bytes()) {
                continue;
            }
            let Ok(files) = fs::read_dir(dir.path()) else { continue };
            for file in files.flatten() {
                let fname = file.file_name();
                let Some(rest) = fname.to_str() else { continue };
                if rest.len() != 38 || !is_lower_hex(rest.as_bytes()) {
                    continue;
                }
                if !file.file_type().map_or(false, |t| t.is_file()) {
                    continue;
                }
                if let Some(id) = ObjectId::from_hex(format!("{prefix}{rest}").as_bytes()) {
                    self.loose.push(id);
                }
            }
        }
        self.loose.sort_unstable();
    }

    fn scan_packs(&mut self) {
        let pack_dir = self.objects_dir.join("pack");
        let Ok(entries) = fs::read_dir(&pack_dir) else { return };
        let mut stems: Vec<String> = entries
            .flatten()
            .filter_map(|e| e.file_name().to_str().and_then(|n| n.strip_suffix(".idx")).map(str::to_owned))
            .collect();
        stems.sort();
        for stem in stems {
            let (Ok(idx), Ok(pack)) = (
                fs::read(pack_dir.join(format!("{stem}.idx"))),
                fs::read(pack_dir.join(format!("{stem}.pack"))),
            ) else {
                continue;
            };
            if let Ok(index) = PackIndex::parse(idx) {
                if let Ok(pack) = Pack::new(index, pack) {
                    self.packs.push(pack);
                }
            }
        }
    }

    /// Number of loose object files.
    pub fn loose_count(&self) -> usize {
        self.loose.len()
    }

    /// Number of usable packs.
    pub fn pack_count(&self) -> usize {
        self.packs.len()
    }

    /// Total of the object counts of all packs (an object in two packs
    /// counts twice).
    pub fn packed_object_count(&self) -> usize {
        self.packs.iter().map(|p| p.index.len()).sum()
    }

    /// True if `id` is a loose file or listed in a pack index. The object is
    /// not read.
    pub fn contains(&self, id: &ObjectId) -> bool {
        self.loose.binary_search(id).is_ok() || self.packs.iter().any(|p| p.index.contains(id))
    }

    /// Resolves a hexadecimal abbreviation (lowercase digits) to the one
    /// object whose id starts with it. `None` when no object or more than one
    /// object matches. Runs in O(log N) per source.
    pub fn find_by_prefix(&self, prefix: &[u8]) -> Option<ObjectId> {
        if prefix.is_empty() || prefix.len() > 40 {
            return None;
        }
        let mut low = [0u8; 20];
        for (i, &c) in prefix.iter().enumerate() {
            let v = if c <= b'9' { c - b'0' } else { c - b'a' + 10 };
            low[i / 2] |= v << if i % 2 == 0 { 4 } else { 0 };
        }
        let matches = |id: &ObjectId| {
            prefix.iter().enumerate().all(|(i, &c)| {
                let v = if c <= b'9' { c - b'0' } else { c - b'a' + 10 };
                (id.as_bytes()[i / 2] >> if i % 2 == 0 { 4 } else { 0 }) & 15 == v
            })
        };
        let mut found: Vec<ObjectId> = Vec::new();
        let note = |id: ObjectId, found: &mut Vec<ObjectId>| {
            if !found.contains(&id) {
                found.push(id);
            }
        };
        let start = self.loose.partition_point(|id| id.as_bytes() < &low);
        for id in self.loose[start..].iter().take_while(|id| matches(id)).take(2) {
            note(*id, &mut found);
        }
        for pack in &self.packs {
            let mut i = pack.index.lower_bound(&low);
            while i < pack.index.len() && found.len() < 2 {
                let id = pack.index.id_at(i);
                if !matches(&id) {
                    break;
                }
                note(id, &mut found);
                i += 1;
            }
        }
        if found.len() == 1 {
            Some(found[0])
        } else {
            None
        }
    }

    /// Reads and reconstructs an object, using the cache when possible.
    /// The content is *not* checked against the id.
    pub fn read(&self, id: &ObjectId) -> Result<Rc<Object>> {
        self.read_depth(id, 0)
    }

    fn read_depth(&self, id: &ObjectId, depth: u32) -> Result<Rc<Object>> {
        if let Some(o) = self.cache.borrow().get(id) {
            return Ok(Rc::clone(o));
        }
        if depth > MAX_DELTA_DEPTH {
            return Err(Error::corrupt("delta chain too deep"));
        }
        let object = if self.loose.binary_search(id).is_ok() {
            Rc::new(self.read_loose(id)?)
        } else {
            let mut found = None;
            for (pi, pack) in self.packs.iter().enumerate() {
                if let Some(offset) = pack.index.find(id) {
                    found = Some(self.read_packed(pi, offset?, depth)?);
                    break;
                }
            }
            found.ok_or_else(|| Error::not_found(format!("object {id}")))?
        };
        self.cache.borrow_mut().insert(*id, Rc::clone(&object));
        Ok(object)
    }

    fn read_loose(&self, id: &ObjectId) -> Result<Object> {
        let hex = id.to_hex();
        let path = self.objects_dir.join(&hex[..2]).join(&hex[2..]);
        let raw = fs::read(&path).map_err(|e| Error::Io(format!("{}: {e}", path.display())))?;
        let plain = zlib_decompress(&raw)?.data;
        let sp = plain
            .iter()
            .position(|&b| b == b' ')
            .ok_or_else(|| Error::corrupt("loose object header"))?;
        let kind = Kind::from_name(&plain[..sp]).ok_or_else(|| Error::corrupt("loose object type"))?;
        let nul = plain
            .iter()
            .position(|&b| b == 0)
            .filter(|&n| n > sp + 1)
            .ok_or_else(|| Error::corrupt("loose object header"))?;
        let digits = &plain[sp + 1..nul];
        if !digits.iter().all(u8::is_ascii_digit) {
            return Err(Error::corrupt("loose object size"));
        }
        let size = digits
            .iter()
            .try_fold(0usize, |acc, &d| acc.checked_mul(10)?.checked_add((d - b'0') as usize))
            .ok_or_else(|| Error::corrupt("loose object size"))?;
        let data = plain[nul + 1..].to_vec();
        if data.len() != size {
            return Err(Error::corrupt("loose object size mismatch"));
        }
        Ok(Object { kind, data })
    }

    fn read_packed(&self, pack_index: usize, offset: u64, depth: u32) -> Result<Rc<Object>> {
        if let Some(o) = self.pack_cache.borrow().get(&(pack_index, offset)) {
            return Ok(Rc::clone(o));
        }
        if depth > MAX_DELTA_DEPTH {
            return Err(Error::corrupt("delta chain too deep"));
        }
        let object = match self.packs[pack_index].entry_at(offset)? {
            PackEntry::Base { kind, data } => Object { kind, data },
            PackEntry::OfsDelta { base_offset, delta } => {
                let base = self.read_packed(pack_index, base_offset, depth + 1)?;
                Object { kind: base.kind, data: apply_delta(&base.data, &delta)? }
            }
            PackEntry::RefDelta { base, delta } => {
                let base = self.read_depth(&base, depth + 1)?;
                Object { kind: base.kind, data: apply_delta(&base.data, &delta)? }
            }
        };
        let object = Rc::new(object);
        self.pack_cache.borrow_mut().insert((pack_index, offset), Rc::clone(&object));
        Ok(object)
    }
}
