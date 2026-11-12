//! Internal storage: an arena of resting orders and the per-price FIFO
//! queues threaded through it as intrusive doubly linked lists.
//!
//! Unlinking an order from the middle of a queue is O(1), and each level
//! keeps its total quantity and order count up to date.

use crate::types::{OrderId, Price, Qty, Side};

/// Index of an order in the [`Arena`].
pub(crate) type Slot = u32;

/// Sentinel for "no node".
pub(crate) const NIL: Slot = u32::MAX;

/// A resting order.
pub(crate) struct Node {
    pub id: OrderId,
    pub side: Side,
    pub price: Price,
    /// Remaining quantity.
    pub qty: Qty,
    prev: Slot,
    next: Slot,
}

/// Slab allocator for [`Node`]s with a free list.
#[derive(Default)]
pub(crate) struct Arena {
    nodes: Vec<Node>,
    free: Vec<Slot>,
}

impl Arena {
    pub fn alloc(&mut self, id: OrderId, side: Side, price: Price, qty: Qty) -> Slot {
        let node = Node { id, side, price, qty, prev: NIL, next: NIL };
        if let Some(slot) = self.free.pop() {
            self.nodes[slot as usize] = node;
            slot
        } else {
            self.nodes.push(node);
            (self.nodes.len() - 1) as Slot
        }
    }

    pub fn release(&mut self, slot: Slot) {
        self.free.push(slot);
    }

    #[inline]
    pub fn get(&self, slot: Slot) -> &Node {
        &self.nodes[slot as usize]
    }

    #[inline]
    pub fn get_mut(&mut self, slot: Slot) -> &mut Node {
        &mut self.nodes[slot as usize]
    }
}

/// One price level: a FIFO queue of orders plus running totals.
pub(crate) struct Level {
    pub head: Slot,
    tail: Slot,
    /// Sum of the remaining quantities of the queued orders.
    pub total: Qty,
    /// Number of queued orders.
    pub count: u32,
}

impl Level {
    pub fn new() -> Level {
        Level { head: NIL, tail: NIL, total: 0, count: 0 }
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.head == NIL
    }

    /// Appends `slot` at the back of the queue.
    pub fn push_back(&mut self, arena: &mut Arena, slot: Slot) {
        let tail = self.tail;
        let node = arena.get_mut(slot);
        node.prev = tail;
        node.next = NIL;
        self.total += node.qty;
        self.count += 1;
        if tail == NIL {
            self.head = slot;
        } else {
            arena.get_mut(tail).next = slot;
        }
        self.tail = slot;
    }

    /// Removes `slot` (which must be queued here) from anywhere in the queue.
    pub fn unlink(&mut self, arena: &mut Arena, slot: Slot) {
        let node = arena.get(slot);
        let (prev, next, qty) = (node.prev, node.next, node.qty);
        if prev == NIL {
            self.head = next;
        } else {
            arena.get_mut(prev).next = next;
        }
        if next == NIL {
            self.tail = prev;
        } else {
            arena.get_mut(next).prev = prev;
        }
        self.total -= qty;
        self.count -= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn collect(level: &Level, arena: &Arena) -> Vec<String> {
        let mut v = Vec::new();
        let mut s = level.head;
        while s != NIL {
            v.push(arena.get(s).id.to_string());
            s = arena.get(s).next;
        }
        v
    }

    #[test]
    fn fifo_and_middle_removal() {
        let mut arena = Arena::default();
        let mut level = Level::new();
        let mk = |arena: &mut Arena, name: &str, q| {
            arena.alloc(OrderId::new(name).unwrap(), Side::Buy, 10, q)
        };
        let a = mk(&mut arena, "a", 1);
        let b = mk(&mut arena, "b", 2);
        let c = mk(&mut arena, "c", 4);
        for s in [a, b, c] {
            level.push_back(&mut arena, s);
        }
        assert_eq!((level.total, level.count), (7, 3));
        level.unlink(&mut arena, b);
        assert_eq!(collect(&level, &arena), ["a", "c"]);
        assert_eq!((level.total, level.count), (5, 2));
        level.unlink(&mut arena, a);
        level.unlink(&mut arena, c);
        assert!(level.is_empty());
        assert_eq!((level.total, level.count), (0, 0));
    }

    #[test]
    fn slots_are_reused() {
        let mut arena = Arena::default();
        let a = arena.alloc(OrderId::new("a").unwrap(), Side::Sell, 1, 1);
        arena.release(a);
        let b = arena.alloc(OrderId::new("b").unwrap(), Side::Sell, 1, 1);
        assert_eq!(a, b);
        assert_eq!(arena.get(b).id.as_str(), "b");
    }
}
