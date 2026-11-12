package orderbook

// order is a resting order. Orders form an intrusive doubly linked list inside
// their level, which makes removal from the middle O(1).
type order struct {
	id         string
	qty        uint64 // remaining quantity
	side       Side
	lvl        *level
	prev, next *order
}

// level is one price level: a FIFO queue of orders plus running totals. It is
// also a node of the side's treap, so it carries the tree links.
type level struct {
	price       uint64
	total       uint64
	count       int
	head, tail  *order
	left, right *level
	prio        uint32
}

func (l *level) pushBack(o *order) {
	o.lvl = l
	o.prev = l.tail
	o.next = nil
	if l.tail != nil {
		l.tail.next = o
	} else {
		l.head = o
	}
	l.tail = o
	l.total += o.qty
	l.count++
}

func (l *level) unlink(o *order) {
	if o.prev != nil {
		o.prev.next = o.next
	} else {
		l.head = o.next
	}
	if o.next != nil {
		o.next.prev = o.prev
	} else {
		l.tail = o.prev
	}
	o.prev, o.next = nil, nil
	l.total -= o.qty
	l.count--
}
