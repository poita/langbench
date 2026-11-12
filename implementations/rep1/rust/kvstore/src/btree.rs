//! Canonical B+tree pages and the tree algorithms of spec §11 and §12:
//! search, insert/replace, splitting, deletion with borrow/merge, range
//! cursors and whole-tree release.
//!
//! The same code serves the primary tree (type-1 leaves) and every index tree
//! (type-5 leaves); the leaf type follows from the [`TreeId`].

use crate::error::{Error, Result};
use crate::header::Page;
use crate::pager::{Pager, TreeId};
use crate::{CAPACITY, MIN_FILL, PAGE_SIZE};

/// Page type byte of a primary leaf.
pub const PRIMARY_LEAF: u8 = 1;
/// Page type byte of an interior page.
pub const INTERIOR: u8 = 2;
/// Page type byte of an index leaf.
pub const INDEX_LEAF: u8 = 5;

fn leaf_type(tree: TreeId) -> u8 {
    match tree {
        TreeId::Primary => PRIMARY_LEAF,
        TreeId::Index(_) => INDEX_LEAF,
    }
}

/// One cell. Which fields are meaningful depends on the page type:
/// primary leaf: `key`, `doc_len`, `overflow`, `inline`; interior: `key`,
/// `child`; index leaf: `key`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Cell {
    /// The cell's key bytes.
    pub key: Vec<u8>,
    /// Child page (interior cells).
    pub child: u32,
    /// Total serialised document length (primary leaf cells).
    pub doc_len: u32,
    /// First overflow page, `0` if none (primary leaf cells).
    pub overflow: u32,
    /// Document bytes held in the cell (primary leaf cells).
    pub inline: Vec<u8>,
}

impl Cell {
    /// An index leaf cell.
    pub fn index(key: Vec<u8>) -> Cell {
        Cell { key, ..Cell::default() }
    }

    /// An interior cell.
    pub fn inner(key: Vec<u8>, child: u32) -> Cell {
        Cell { key, child, ..Cell::default() }
    }

    /// Encoded size of the cell on a page of type `ty`.
    fn size(&self, ty: u8) -> usize {
        match ty {
            PRIMARY_LEAF => 12 + self.key.len() + self.inline.len(),
            INTERIOR => 6 + self.key.len(),
            _ => 2 + self.key.len(),
        }
    }
}

/// A decoded page: its type, cells in key order and its `link` field.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Node {
    /// Page type byte.
    pub ty: u8,
    /// Cells in ascending key order.
    pub cells: Vec<Cell>,
    /// Rightmost child (interior) or next leaf (leaf).
    pub link: u32,
}

fn be16(b: &[u8], at: usize) -> usize {
    u16::from_be_bytes([b[at], b[at + 1]]) as usize
}

fn be32(b: &[u8], at: usize) -> u32 {
    u32::from_be_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}

impl Node {
    /// An empty node of type `ty`.
    pub fn empty(ty: u8) -> Node {
        Node { ty, cells: Vec::new(), link: 0 }
    }

    /// Cost of a cell: its size plus its 2-byte pointer.
    fn cost(&self, c: &Cell) -> usize {
        c.size(self.ty) + 2
    }

    /// The payload size `used(page)` of spec §11.2.
    pub fn used(&self) -> usize {
        self.cells.iter().map(|c| self.cost(c)).sum()
    }

    /// Decodes a page.
    pub fn decode(page: &Page) -> Result<Node> {
        let ty = page[0];
        if ty != PRIMARY_LEAF && ty != INTERIOR && ty != INDEX_LEAF {
            return Err(Error::Corrupt);
        }
        let n = be16(page, 2);
        let link = be32(page, 8);
        let mut cells = Vec::with_capacity(n);
        for i in 0..n {
            let off = be16(page, 16 + 2 * i);
            if off + 2 > PAGE_SIZE {
                return Err(Error::Corrupt);
            }
            let key_len = be16(page, off);
            let cell = match ty {
                PRIMARY_LEAF => {
                    let doc_len = be32(page, off + 2);
                    let inline_len = be16(page, off + 6);
                    let overflow = be32(page, off + 8);
                    let k = off + 12;
                    if k + key_len + inline_len > PAGE_SIZE {
                        return Err(Error::Corrupt);
                    }
                    Cell {
                        key: page[k..k + key_len].to_vec(),
                        child: 0,
                        doc_len,
                        overflow,
                        inline: page[k + key_len..k + key_len + inline_len].to_vec(),
                    }
                }
                INTERIOR => {
                    let child = be32(page, off + 2);
                    let k = off + 6;
                    if k + key_len > PAGE_SIZE {
                        return Err(Error::Corrupt);
                    }
                    Cell::inner(page[k..k + key_len].to_vec(), child)
                }
                _ => {
                    let k = off + 2;
                    if k + key_len > PAGE_SIZE {
                        return Err(Error::Corrupt);
                    }
                    Cell::index(page[k..k + key_len].to_vec())
                }
            };
            cells.push(cell);
        }
        Ok(Node { ty, cells, link })
    }

    /// Encodes the node canonically (spec §11.2).
    pub fn encode(&self) -> Page {
        let mut page = [0u8; PAGE_SIZE];
        let total: usize = self.cells.iter().map(|c| c.size(self.ty)).sum();
        let start = PAGE_SIZE - total;
        page[0] = self.ty;
        page[2..4].copy_from_slice(&(self.cells.len() as u16).to_be_bytes());
        page[4..6].copy_from_slice(&(start as u16).to_be_bytes());
        page[8..12].copy_from_slice(&self.link.to_be_bytes());
        let mut off = start;
        for (i, c) in self.cells.iter().enumerate() {
            page[16 + 2 * i..18 + 2 * i].copy_from_slice(&(off as u16).to_be_bytes());
            let klen = (c.key.len() as u16).to_be_bytes();
            match self.ty {
                PRIMARY_LEAF => {
                    page[off..off + 2].copy_from_slice(&klen);
                    page[off + 2..off + 6].copy_from_slice(&c.doc_len.to_be_bytes());
                    page[off + 6..off + 8].copy_from_slice(&(c.inline.len() as u16).to_be_bytes());
                    page[off + 8..off + 12].copy_from_slice(&c.overflow.to_be_bytes());
                    page[off + 12..off + 12 + c.key.len()].copy_from_slice(&c.key);
                    let at = off + 12 + c.key.len();
                    page[at..at + c.inline.len()].copy_from_slice(&c.inline);
                }
                INTERIOR => {
                    page[off..off + 2].copy_from_slice(&klen);
                    page[off + 2..off + 6].copy_from_slice(&c.child.to_be_bytes());
                    page[off + 6..off + 6 + c.key.len()].copy_from_slice(&c.key);
                }
                _ => {
                    page[off..off + 2].copy_from_slice(&klen);
                    page[off + 2..off + 2 + c.key.len()].copy_from_slice(&c.key);
                }
            }
            off += c.size(self.ty);
        }
        page
    }

    /// Index of the child to descend for `key`: the smallest `i` with
    /// `key <= k[i]`, or `cells.len()` for the `link`.
    fn child_index(&self, key: &[u8]) -> usize {
        self.cells.partition_point(|c| c.key.as_slice() < key)
    }

    /// The child page at index `i` (`cells.len()` is the `link`).
    fn child_at(&self, i: usize) -> u32 {
        if i == self.cells.len() {
            self.link
        } else {
            self.cells[i].child
        }
    }
}

fn load(pager: &Pager, page: u32) -> Result<Node> {
    Node::decode(&pager.read_page(page))
}

fn store_node(pager: &mut Pager, page: u32, node: &Node) {
    pager.write_page(page, &node.encode());
}

/// One step of a root-to-leaf path: the interior page, its decoded node and
/// the child index taken.
struct Step {
    page: u32,
    node: Node,
    idx: usize,
}

/// Descends to the leaf for `key`, recording the path.
fn descend(pager: &Pager, tree: TreeId, key: &[u8]) -> Result<(Vec<Step>, u32, Node)> {
    let mut page = pager.root(tree);
    let mut path = Vec::new();
    loop {
        let node = load(pager, page)?;
        if node.ty != INTERIOR {
            return Ok((path, page, node));
        }
        let idx = node.child_index(key);
        let next = node.child_at(idx);
        path.push(Step { page, node, idx });
        page = next;
    }
}

/// Looks `key` up in `tree`.
pub fn get(pager: &Pager, tree: TreeId, key: &[u8]) -> Result<Option<Cell>> {
    if pager.root(tree) == 0 {
        return Ok(None);
    }
    let (_, _, leaf) = descend(pager, tree, key)?;
    Ok(leaf
        .cells
        .binary_search_by(|c| c.key.as_slice().cmp(key))
        .ok()
        .map(|i| leaf.cells[i].clone()))
}

/// The split point `m` of an overflowing node (spec §12.3).
fn split_point(node: &Node) -> usize {
    let total = node.used();
    let mut prefix = 0;
    for (m, c) in node.cells.iter().enumerate() {
        if m >= 1 && 2 * prefix >= total {
            return m;
        }
        prefix += node.cost(c);
    }
    node.cells.len() - 1
}

/// Writes `node` to `page`, splitting it (and its ancestors on `path`) while
/// it overflows.
fn store_with_splits(pager: &mut Pager, tree: TreeId, mut page: u32, mut node: Node, mut path: Vec<Step>) {
    loop {
        if node.used() <= CAPACITY {
            store_node(pager, page, &node);
            return;
        }
        let m = split_point(&node);
        let right_no = pager.allocate();
        let right_cells = node.cells.split_off(m);
        let sep;
        let right;
        if node.ty == INTERIOR {
            let promoted = node.cells.pop().expect("interior split keeps a cell");
            right = Node { ty: INTERIOR, cells: right_cells, link: node.link };
            node.link = promoted.child;
            sep = promoted.key;
        } else {
            right = Node { ty: node.ty, cells: right_cells, link: node.link };
            node.link = right_no;
            sep = node.cells.last().expect("leaf split keeps a cell").key.clone();
        }
        store_node(pager, page, &node);
        store_node(pager, right_no, &right);
        match path.pop() {
            None => {
                let new_root = pager.allocate();
                let root = Node { ty: INTERIOR, cells: vec![Cell::inner(sep, page)], link: right_no };
                store_node(pager, new_root, &root);
                pager.set_root(tree, new_root);
                return;
            }
            Some(Step { page: pp, node: mut pn, idx: j }) => {
                if j == pn.cells.len() {
                    pn.cells.push(Cell::inner(sep, page));
                    pn.link = right_no;
                } else {
                    pn.cells[j].child = right_no;
                    pn.cells.insert(j, Cell::inner(sep, page));
                }
                page = pp;
                node = pn;
            }
        }
    }
}

/// Inserts `cell`, or replaces the cell with the same key in place. Returns
/// `true` if an existing cell was replaced.
pub fn insert(pager: &mut Pager, tree: TreeId, cell: Cell) -> Result<bool> {
    if pager.root(tree) == 0 {
        let root = pager.allocate();
        store_node(pager, root, &Node::empty(leaf_type(tree)));
        pager.set_root(tree, root);
    }
    let (path, page, mut leaf) = descend(pager, tree, &cell.key)?;
    let replaced = match leaf.cells.binary_search_by(|c| c.key.cmp(&cell.key)) {
        Ok(i) => {
            leaf.cells[i] = cell;
            true
        }
        Err(i) => {
            leaf.cells.insert(i, cell);
            false
        }
    };
    store_with_splits(pager, tree, page, leaf, path);
    Ok(replaced)
}

/// Deletes `key`, repairing underflow by borrowing and merging (spec §12.4,
/// §12.5). Returns `false`, changing nothing, if the key is absent.
pub fn delete(pager: &mut Pager, tree: TreeId, key: &[u8]) -> Result<bool> {
    if pager.root(tree) == 0 {
        return Ok(false);
    }
    let (path, page, mut leaf) = descend(pager, tree, key)?;
    let Ok(i) = leaf.cells.binary_search_by(|c| c.key.as_slice().cmp(key)) else {
        return Ok(false);
    };
    leaf.cells.remove(i);
    if path.is_empty() {
        if leaf.cells.is_empty() {
            pager.free(page);
            pager.set_root(tree, 0);
        } else {
            store_node(pager, page, &leaf);
        }
    } else if leaf.used() >= MIN_FILL {
        store_node(pager, page, &leaf);
    } else {
        rebalance(pager, tree, page, leaf, path)?;
    }
    Ok(true)
}

/// Repairs the underflowing non-root node `node` stored at `page`.
fn rebalance(pager: &mut Pager, tree: TreeId, mut page: u32, mut node: Node, mut path: Vec<Step>) -> Result<()> {
    loop {
        let Step { page: pp, node: mut pn, idx: j } = path.pop().expect("non-root node has a parent");
        let n_p = pn.cells.len();
        let left = if j >= 1 {
            let lp = pn.cells[j - 1].child;
            Some((lp, load(pager, lp)?))
        } else {
            None
        };
        let right = if j < n_p {
            let rp = pn.child_at(j + 1);
            Some((rp, load(pager, rp)?))
        } else {
            None
        };
        let interior = node.ty == INTERIOR;

        // 1. borrow from the left
        if let Some((lp, l)) = &left {
            let last = l.cells.last().expect("sibling has a cell");
            if l.used() - l.cost(last) >= MIN_FILL {
                let (lp, mut l) = (*lp, l.clone());
                let moved = l.cells.pop().expect("checked");
                if interior {
                    node.cells.insert(0, Cell::inner(pn.cells[j - 1].key.clone(), l.link));
                    pn.cells[j - 1].key = moved.key;
                    l.link = moved.child;
                } else {
                    node.cells.insert(0, moved);
                    pn.cells[j - 1].key = l.cells.last().expect("checked").key.clone();
                }
                store_node(pager, lp, &l);
                store_node(pager, page, &node);
                store_with_splits(pager, tree, pp, pn, path);
                return Ok(());
            }
        }
        // 2. borrow from the right
        if let Some((rp, r)) = &right {
            let first = r.cells.first().expect("sibling has a cell");
            if r.used() - r.cost(first) >= MIN_FILL {
                let (rp, mut r) = (*rp, r.clone());
                let moved = r.cells.remove(0);
                if interior {
                    node.cells.push(Cell::inner(pn.cells[j].key.clone(), node.link));
                    node.link = moved.child;
                    pn.cells[j].key = moved.key;
                } else {
                    pn.cells[j].key = moved.key.clone();
                    node.cells.push(moved);
                }
                store_node(pager, rp, &r);
                store_node(pager, page, &node);
                store_with_splits(pager, tree, pp, pn, path);
                return Ok(());
            }
        }
        // 3. merge with the left (the left page survives)
        if let Some((lp, mut l)) = left {
            if interior {
                l.cells.push(Cell::inner(pn.cells[j - 1].key.clone(), l.link));
            }
            l.cells.extend(node.cells);
            l.link = node.link;
            store_node(pager, lp, &l);
            pn.cells.remove(j - 1);
            if j == n_p {
                pn.link = lp;
            } else {
                pn.cells[j - 1].child = lp;
            }
            pager.free(page);
        } else if let Some((rp, r)) = right {
            // 4. merge with the right (this page survives)
            if interior {
                node.cells.push(Cell::inner(pn.cells[j].key.clone(), node.link));
            }
            node.cells.extend(r.cells);
            node.link = r.link;
            store_node(pager, page, &node);
            pn.cells.remove(j);
            if j + 1 == n_p {
                pn.link = page;
            } else {
                pn.cells[j].child = page;
            }
            pager.free(rp);
        } else {
            return Err(Error::Corrupt);
        }
        // Propagate upward.
        if path.is_empty() {
            if pn.cells.is_empty() {
                pager.set_root(tree, pn.link);
                pager.free(pp);
            } else {
                store_node(pager, pp, &pn);
            }
            return Ok(());
        }
        if pn.used() >= MIN_FILL {
            store_node(pager, pp, &pn);
            return Ok(());
        }
        page = pp;
        node = pn;
    }
}

/// Frees every page of the tree rooted at `page` in post-order (spec §12.6).
/// Returns the number of pages freed.
pub fn free_tree(pager: &mut Pager, page: u32) -> Result<usize> {
    if page == 0 {
        return Ok(0);
    }
    let node = load(pager, page)?;
    let mut freed = 0;
    if node.ty == INTERIOR {
        for i in 0..=node.cells.len() {
            freed += free_tree(pager, node.child_at(i))?;
        }
    }
    pager.free(page);
    Ok(freed + 1)
}

/// Height of a tree: 0 when empty, 1 for a lone leaf, and so on.
pub fn height(pager: &Pager, tree: TreeId) -> Result<usize> {
    let mut page = pager.root(tree);
    let mut h = 0;
    while page != 0 {
        h += 1;
        let node = load(pager, page)?;
        if node.ty != INTERIOR {
            break;
        }
        page = node.child_at(0);
    }
    Ok(h)
}

/// A forward cursor over the cells of a tree in key order. A walk costs one
/// descent plus one page read per leaf visited.
pub struct Cursor {
    cells: std::vec::IntoIter<Cell>,
    next_leaf: u32,
}

impl Cursor {
    /// Positions a cursor at the first cell whose key is `>= from`
    /// (the first cell of the tree if `from` is `None`).
    pub fn seek(pager: &Pager, tree: TreeId, from: Option<&[u8]>) -> Result<Cursor> {
        let mut page = pager.root(tree);
        if page == 0 {
            return Ok(Cursor { cells: Vec::new().into_iter(), next_leaf: 0 });
        }
        loop {
            let mut node = load(pager, page)?;
            if node.ty == INTERIOR {
                let idx = from.map_or(0, |k| node.child_index(k));
                page = node.child_at(idx);
                continue;
            }
            let start = from.map_or(0, |k| node.cells.partition_point(|c| c.key.as_slice() < k));
            let cells = node.cells.split_off(start);
            return Ok(Cursor { cells: cells.into_iter(), next_leaf: node.link });
        }
    }

    /// The next cell in ascending key order.
    pub fn next(&mut self, pager: &Pager) -> Result<Option<Cell>> {
        loop {
            if let Some(c) = self.cells.next() {
                return Ok(Some(c));
            }
            if self.next_leaf == 0 {
                return Ok(None);
            }
            let leaf = load(pager, self.next_leaf)?;
            self.next_leaf = leaf.link;
            self.cells = leaf.cells.into_iter();
        }
    }
}

/// A backward cursor over the cells of a tree in descending key order.
pub struct RevCursor {
    stack: Vec<(Node, usize)>,
    cells: Vec<Cell>,
}

impl RevCursor {
    /// Positions a cursor at the last cell whose key is `< before`
    /// (the last cell of the tree if `before` is `None`).
    pub fn seek(pager: &Pager, tree: TreeId, before: Option<&[u8]>) -> Result<RevCursor> {
        let mut cur = RevCursor { stack: Vec::new(), cells: Vec::new() };
        let page = pager.root(tree);
        if page == 0 {
            return Ok(cur);
        }
        cur.descend(pager, page, before)?;
        Ok(cur)
    }

    /// Descends from `page` to a leaf: towards `before` if given, otherwise
    /// along the rightmost edge. Keeps in `cells` the leaf cells below the
    /// bound.
    fn descend(&mut self, pager: &Pager, mut page: u32, before: Option<&[u8]>) -> Result<()> {
        loop {
            let mut node = load(pager, page)?;
            if node.ty == INTERIOR {
                let idx = before.map_or(node.cells.len(), |k| node.child_index(k));
                page = node.child_at(idx);
                self.stack.push((node, idx));
            } else {
                if let Some(k) = before {
                    let n = node.cells.partition_point(|c| c.key.as_slice() < k);
                    node.cells.truncate(n);
                }
                self.cells = node.cells;
                return Ok(());
            }
        }
    }

    /// The next cell in descending key order.
    pub fn next(&mut self, pager: &Pager) -> Result<Option<Cell>> {
        loop {
            if let Some(c) = self.cells.pop() {
                return Ok(Some(c));
            }
            // Climb to the nearest ancestor with a child to the left.
            loop {
                let Some((node, idx)) = self.stack.pop() else { return Ok(None) };
                if idx > 0 {
                    let child = node.child_at(idx - 1);
                    self.stack.push((node, idx - 1));
                    self.descend(pager, child, None)?;
                    break;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::header::Header;
    use crate::wal;
    use std::collections::BTreeMap;

    fn pager() -> Pager {
        Pager::new(Header::fresh().encode().to_vec(), BTreeMap::new(), wal::header_bytes().to_vec()).unwrap()
    }

    fn idx_cell(i: usize) -> Cell {
        // Keys of varied length so splits land in different places.
        Cell::index(format!("{:05}{}", i, "x".repeat(i % 37)).into_bytes())
    }

    fn collect(pager: &Pager) -> Vec<Vec<u8>> {
        let mut c = Cursor::seek(pager, TreeId::Index(0), None).unwrap();
        let mut out = Vec::new();
        while let Some(cell) = c.next(pager).unwrap() {
            out.push(cell.key);
        }
        out
    }

    fn check_invariants(pager: &Pager, tree: TreeId) {
        fn walk(pager: &Pager, page: u32, depth: usize, leaf_depth: &mut Option<usize>, root: bool) {
            let node = load(pager, page).unwrap();
            assert!(node.used() <= CAPACITY);
            assert_eq!(node.encode(), pager.read_page(page), "page {page} is canonical");
            if !root {
                assert!(!node.cells.is_empty(), "non-root page {page} holds a cell");
            }
            if node.ty == INTERIOR {
                for i in 0..=node.cells.len() {
                    walk(pager, node.child_at(i), depth + 1, leaf_depth, false);
                }
            } else {
                match leaf_depth {
                    None => *leaf_depth = Some(depth),
                    Some(d) => assert_eq!(*d, depth),
                }
            }
        }
        let root = pager.root(tree);
        if root != 0 {
            walk(pager, root, 0, &mut None, true);
        }
    }

    fn setup() -> Pager {
        let mut p = pager();
        p.header.slots[0].live = true;
        p.header.slots[0].path = "a".into();
        p
    }

    #[test]
    fn insert_search_and_scan_in_both_directions() {
        let mut p = setup();
        let tree = TreeId::Index(0);
        let n = 700;
        // A scrambled but deterministic insertion order.
        let order: Vec<usize> = (0..n).map(|i| (i * 389) % n).collect();
        for &i in &order {
            assert!(!insert(&mut p, tree, idx_cell(i)).unwrap());
        }
        check_invariants(&p, tree);
        assert!(height(&p, tree).unwrap() >= 3);
        assert!(insert(&mut p, tree, idx_cell(5)).unwrap());
        let keys = collect(&p);
        assert_eq!(keys.len(), n);
        assert!(keys.windows(2).all(|w| w[0] < w[1]));
        for i in (0..n).step_by(13) {
            assert!(get(&p, tree, &idx_cell(i).key).unwrap().is_some());
        }
        assert!(get(&p, tree, b"zzz").unwrap().is_none());
        let mut rev = RevCursor::seek(&p, tree, None).unwrap();
        let mut back = Vec::new();
        while let Some(c) = rev.next(&p).unwrap() {
            back.push(c.key);
        }
        back.reverse();
        assert_eq!(back, keys);
        // Bounded cursors.
        let from = keys[100].clone();
        let mut c = Cursor::seek(&p, tree, Some(&from)).unwrap();
        assert_eq!(c.next(&p).unwrap().unwrap().key, from);
        let mut rev = RevCursor::seek(&p, tree, Some(&from)).unwrap();
        assert_eq!(rev.next(&p).unwrap().unwrap().key, keys[99]);
    }

    #[test]
    fn delete_everything_in_scrambled_order() {
        let mut p = setup();
        let tree = TreeId::Index(0);
        let n = 600;
        for i in 0..n {
            insert(&mut p, tree, idx_cell(i)).unwrap();
        }
        let pages_after_build = p.header.page_count;
        for k in 0..n {
            let i = (k * 257) % n;
            assert!(delete(&mut p, tree, &idx_cell(i).key).unwrap());
            assert!(!delete(&mut p, tree, &idx_cell(i).key).unwrap());
            if k % 50 == 0 {
                check_invariants(&p, tree);
                assert_eq!(collect(&p).len(), n - k - 1);
            }
        }
        assert_eq!(p.root(tree), 0);
        // Every page ever allocated is now on the free list.
        assert_eq!(p.header.freelist_count + 1, p.header.page_count);
        assert!(p.header.page_count >= pages_after_build);
    }

    #[test]
    fn free_tree_releases_every_page() {
        let mut p = setup();
        let tree = TreeId::Index(0);
        for i in 0..300 {
            insert(&mut p, tree, idx_cell(i)).unwrap();
        }
        let root = p.root(tree);
        let freed = free_tree(&mut p, root).unwrap();
        assert_eq!(freed as u32, p.header.freelist_count);
        assert_eq!(p.header.freelist_count + 1, p.header.page_count);
    }

    #[test]
    fn leaf_split_follows_the_spec() {
        // Spec §21.12: six primary cells of cost 201 split 3/3 at the sixth.
        let mut p = pager();
        let tree = TreeId::Primary;
        for i in 1..=6 {
            let cell = Cell {
                key: format!("k{i}").into_bytes(),
                child: 0,
                doc_len: 185,
                overflow: 0,
                inline: vec![i as u8; 185],
            };
            insert(&mut p, tree, cell).unwrap();
        }
        assert_eq!(p.header.page_count, 4);
        assert_eq!(p.root(tree), 4);
        let root = load(&p, 4).unwrap();
        assert_eq!(root.cells.len(), 1);
        assert_eq!(root.cells[0].key, b"k3");
        assert_eq!((root.cells[0].child, root.link), (2, 3));
        assert_eq!(load(&p, 2).unwrap().link, 3);
        assert_eq!(height(&p, tree).unwrap(), 2);
    }
}
