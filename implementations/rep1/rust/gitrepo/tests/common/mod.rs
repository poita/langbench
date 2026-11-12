//! Helpers that build small git repositories on disk without git.
#![allow(dead_code)]

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use gitrepo::sha1::hash_object;
use gitrepo::{ObjectId, Repository};

static COUNTER: AtomicUsize = AtomicUsize::new(0);

/// A repository directory that is removed on drop.
pub struct TestRepo {
    pub root: PathBuf,
}

fn adler32(data: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for &d in data {
        a = (a + d as u32) % 65521;
        b = (b + a) % 65521;
    }
    (b << 16) | a
}

/// A valid zlib stream made of stored (uncompressed) blocks.
pub fn zlib_store(data: &[u8]) -> Vec<u8> {
    let mut out = vec![0x78, 0x01];
    let mut chunks: Vec<&[u8]> = data.chunks(65535).collect();
    if chunks.is_empty() {
        chunks.push(&[]);
    }
    let n = chunks.len();
    for (i, c) in chunks.into_iter().enumerate() {
        out.push(u8::from(i + 1 == n));
        out.extend_from_slice(&(c.len() as u16).to_le_bytes());
        out.extend_from_slice(&(!(c.len() as u16)).to_le_bytes());
        out.extend_from_slice(c);
    }
    out.extend_from_slice(&adler32(data).to_be_bytes());
    out
}

/// A delta that copies the first `keep` bytes of `base` and then inserts the
/// rest of `result`.
pub fn make_delta(base: &[u8], result: &[u8], keep: usize) -> Vec<u8> {
    fn size(mut v: usize, out: &mut Vec<u8>) {
        loop {
            let b = (v & 0x7f) as u8;
            v >>= 7;
            if v == 0 {
                out.push(b);
                return;
            }
            out.push(b | 0x80);
        }
    }
    assert!(base.starts_with(&result[..keep]) && keep < 0x10000);
    let mut d = Vec::new();
    size(base.len(), &mut d);
    size(result.len(), &mut d);
    if keep > 0 {
        d.extend_from_slice(&[0x90, keep as u8]);
        if keep > 255 {
            d.truncate(d.len() - 2);
            d.extend_from_slice(&[0xb0, (keep & 0xff) as u8, (keep >> 8) as u8]);
        }
    }
    for chunk in result[keep..].chunks(127) {
        d.push(chunk.len() as u8);
        d.extend_from_slice(chunk);
    }
    d
}

/// An object to place in a pack.
pub enum PackItem {
    Base(&'static str, Vec<u8>),
    /// Delta against the item at this index of the same pack.
    Ofs(usize, Vec<u8>),
    /// Delta against an object with this id, stored elsewhere.
    Ref(ObjectId, Vec<u8>),
}

impl TestRepo {
    pub fn new() -> TestRepo {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let root = std::env::temp_dir().join(format!("gitrepo-test-{}-{n}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("objects/pack")).unwrap();
        fs::create_dir_all(root.join("refs/heads")).unwrap();
        TestRepo { root }
    }

    pub fn open(&self) -> Repository {
        Repository::open(&self.root).unwrap()
    }

    pub fn write_file(&self, rel: &str, content: &[u8]) {
        let p = self.root.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, content).unwrap();
    }

    /// Writes a loose object and returns its id.
    pub fn loose(&self, kind: &str, payload: &[u8]) -> ObjectId {
        let id = hash_object(kind, payload);
        let mut stored = format!("{kind} {}\0", payload.len()).into_bytes();
        stored.extend_from_slice(payload);
        self.write_raw_loose(&id, &zlib_store(&stored));
        id
    }

    pub fn write_raw_loose(&self, id: &ObjectId, bytes: &[u8]) {
        let hex = id.to_hex();
        self.write_file(&format!("objects/{}/{}", &hex[..2], &hex[2..]), bytes);
    }

    pub fn blob(&self, text: &str) -> ObjectId {
        self.loose("blob", text.as_bytes())
    }

    pub fn tree(&self, entries: &[(&str, &[u8], ObjectId)]) -> ObjectId {
        let mut payload = Vec::new();
        for (mode, name, id) in entries {
            payload.extend_from_slice(mode.as_bytes());
            payload.push(b' ');
            payload.extend_from_slice(name);
            payload.push(0);
            payload.extend_from_slice(id.as_bytes());
        }
        self.loose("tree", &payload)
    }

    pub fn commit(&self, tree: ObjectId, parents: &[ObjectId], time: u64, msg: &str) -> ObjectId {
        let mut text = format!("tree {tree}\n");
        for p in parents {
            text += &format!("parent {p}\n");
        }
        text += &format!("author Ada Lovelace <ada@example.org> {time} +0000\n");
        text += &format!("committer Ada Lovelace <ada@example.org> {time} +0000\n\n{msg}\n");
        self.loose("commit", text.as_bytes())
    }

    pub fn set_ref(&self, name: &str, id: &ObjectId) {
        self.write_file(name, format!("{id}\n").as_bytes());
    }

    /// Writes `objects/pack/<name>.{pack,idx}` holding `items`; `ids[i]` is
    /// the id of `items[i]`.
    pub fn pack(&self, name: &str, items: &[PackItem], ids: &[ObjectId]) {
        let mut pack = b"PACK".to_vec();
        pack.extend_from_slice(&2u32.to_be_bytes());
        pack.extend_from_slice(&(items.len() as u32).to_be_bytes());
        let mut offsets = Vec::new();
        for item in items {
            let offset = pack.len();
            offsets.push(offset);
            let (ty, payload) = match item {
                PackItem::Base(kind, data) => {
                    (match *kind { "commit" => 1, "tree" => 2, "blob" => 3, _ => 4 }, data)
                }
                PackItem::Ofs(_, d) => (6, d),
                PackItem::Ref(_, d) => (7, d),
            };
            let mut size = payload.len();
            let mut first = (ty << 4) | (size & 15) as u8;
            size >>= 4;
            while size > 0 {
                pack.push(first | 0x80);
                first = (size & 0x7f) as u8;
                size >>= 7;
            }
            pack.push(first);
            match item {
                PackItem::Ofs(base, _) => {
                    let mut v = offset - offsets[*base];
                    let mut bytes = vec![(v & 0x7f) as u8];
                    v >>= 7;
                    while v > 0 {
                        v -= 1;
                        bytes.push(0x80 | (v & 0x7f) as u8);
                        v >>= 7;
                    }
                    bytes.reverse();
                    pack.extend_from_slice(&bytes);
                }
                PackItem::Ref(id, _) => pack.extend_from_slice(id.as_bytes()),
                PackItem::Base(..) => {}
            }
            pack.extend_from_slice(&zlib_store(payload));
        }
        pack.extend_from_slice(&[0; 20]);

        let mut order: Vec<usize> = (0..items.len()).collect();
        order.sort_by_key(|&i| ids[i]);
        let mut idx = vec![0xff, b't', b'O', b'c', 0, 0, 0, 2];
        for b in 0..256usize {
            let n = order.iter().filter(|&&i| ids[i].as_bytes()[0] as usize <= b).count();
            idx.extend_from_slice(&(n as u32).to_be_bytes());
        }
        for &i in &order {
            idx.extend_from_slice(ids[i].as_bytes());
        }
        for _ in &order {
            idx.extend_from_slice(&[0; 4]);
        }
        for &i in &order {
            idx.extend_from_slice(&(offsets[i] as u32).to_be_bytes());
        }
        idx.extend_from_slice(&[0; 40]);
        self.write_file(&format!("objects/pack/{name}.pack"), &pack);
        self.write_file(&format!("objects/pack/{name}.idx"), &idx);
    }
}

impl Drop for TestRepo {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// Runs a command and returns stdout as a string, or `None` on failure.
pub fn run(repo: &Repository, line: &str) -> Option<String> {
    gitrepo::commands::execute(repo, line.as_bytes())
        .ok()
        .map(|b| String::from_utf8(b).unwrap())
}
