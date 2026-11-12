package orderbook

// Book is a single-instrument limit order book. Create one with [New]; the
// zero value is not usable. A Book is not safe for concurrent use.
//
// The methods that process commands return the events they produced. The
// returned slice is owned by the Book and is only valid until the next call
// to a command method; copy it if it must be kept.
type Book struct {
	bids, asks *bookSide
	orders     map[string]*order
	spare      []*order
	ev         []Event
}

// New returns an empty book.
func New() *Book {
	return &Book{
		bids:   newSide(true, 0x9e3779b9),
		asks:   newSide(false, 0x85ebca6b),
		orders: make(map[string]*order),
	}
}

// Len returns the number of resting orders.
func (b *Book) Len() int { return len(b.orders) }

// Has reports whether id denotes a currently resting order.
func (b *Book) Has(id string) bool { _, ok := b.orders[id]; return ok }

// Bids returns the non-empty bid levels, best (highest price) first.
func (b *Book) Bids() []Level { return b.bids.levels() }

// Asks returns the non-empty ask levels, best (lowest price) first.
func (b *Book) Asks() []Level { return b.asks.levels() }

// Snapshot returns the book as events: one Bid event per bid level (best
// first), one Ask event per ask level (best first), then EndBook. It does not
// change the book.
func (b *Book) Snapshot() []Event {
	b.ev = b.ev[:0]
	b.bids.each(func(l *level) bool {
		b.ev = append(b.ev, Event{Kind: Bid, Price: l.price, Qty: l.total, Orders: uint64(l.count)})
		return true
	})
	b.asks.each(func(l *level) bool {
		b.ev = append(b.ev, Event{Kind: Ask, Price: l.price, Qty: l.total, Orders: uint64(l.count)})
		return true
	})
	b.ev = append(b.ev, Event{Kind: EndBook})
	return b.ev
}

// Execute runs a generic command and returns its events.
func (b *Book) Execute(c Command) []Event {
	switch c.Kind {
	case CmdLimit:
		return b.Limit(c.ID, c.Side, c.Price, c.Qty, c.TIF)
	case CmdMarket:
		return b.Market(c.ID, c.Side, c.Qty)
	case CmdCancel:
		return b.Cancel(c.ID)
	case CmdReplace:
		return b.Replace(c.ID, c.Price, c.Qty)
	case CmdBook:
		return b.Snapshot()
	}
	panic("orderbook: unknown command kind")
}

// Limit submits a limit order. The order is matched against the opposite
// side at prices no worse than price; what happens to the remainder depends
// on tif (see [TimeInForce]). Ids must be unique among submitted orders; a
// Limit whose id is already resting is rejected.
func (b *Book) Limit(id string, side Side, price, qty uint64, tif TimeInForce) []Event {
	b.ev = b.ev[:0]
	if _, dup := b.orders[id]; dup {
		b.emit(Event{Kind: Reject, ID: id})
		return b.ev
	}
	if tif == FOK && b.available(side, price) < qty {
		b.emit(Event{Kind: Reject, ID: id})
		return b.ev
	}
	b.submit(id, side, price, qty, true, tif)
	return b.ev
}

// Market submits a market order, which takes whatever the opposite side
// offers, best price first, and never rests.
func (b *Book) Market(id string, side Side, qty uint64) []Event {
	b.ev = b.ev[:0]
	b.submit(id, side, 0, qty, false, IOC)
	return b.ev
}

// Cancel removes the resting order id, reporting its remaining quantity, or
// rejects the command if id is not resting.
func (b *Book) Cancel(id string) []Event {
	b.ev = b.ev[:0]
	o, ok := b.orders[id]
	if !ok {
		b.emit(Event{Kind: Reject, ID: id})
		return b.ev
	}
	b.emit(Event{Kind: Cancel, ID: id, Qty: o.qty})
	b.drop(o)
	return b.ev
}

// Replace sets the remaining quantity and price of the resting order id. If
// the price is unchanged and the quantity does not increase the order keeps
// its queue position; otherwise it loses priority and re-enters as a new
// plain limit order with its original side. A Replace of an order that is not
// resting is rejected.
func (b *Book) Replace(id string, price, qty uint64) []Event {
	b.ev = b.ev[:0]
	o, ok := b.orders[id]
	if !ok {
		b.emit(Event{Kind: Reject, ID: id})
		return b.ev
	}
	if price == o.lvl.price && qty <= o.qty {
		o.lvl.total -= o.qty - qty
		o.qty = qty
		b.emit(Event{Kind: Rest, ID: id})
		return b.ev
	}
	side := o.side
	b.drop(o)
	b.submit(id, side, price, qty, true, GTC)
	return b.ev
}

func (b *Book) emit(e Event) { b.ev = append(b.ev, e) }

func (b *Book) sideOf(s Side) *bookSide {
	if s == Buy {
		return b.bids
	}
	return b.asks
}

// available returns the total quantity a taker on side with the given limit
// price could trade against.
func (b *Book) available(side Side, limit uint64) uint64 {
	opp := b.sideOf(side ^ 1)
	var sum uint64
	opp.each(func(l *level) bool {
		if !opp.crosses(l.price, limit) {
			return false
		}
		sum += l.total
		return true
	})
	return sum
}

// drop removes a resting order from the book and the id index.
func (b *Book) drop(o *order) {
	b.sideOf(o.side).remove(o)
	delete(b.orders, o.id)
	*o = order{}
	b.spare = append(b.spare, o)
}

// submit matches a taker and then disposes of its remainder.
func (b *Book) submit(id string, side Side, limit, qty uint64, hasLimit bool, tif TimeInForce) {
	opp := b.sideOf(side ^ 1)
	for qty > 0 {
		l := opp.best
		if l == nil || (hasLimit && !opp.crosses(l.price, limit)) {
			break
		}
		m := l.head
		t := min(qty, m.qty)
		b.emit(Event{Kind: Trade, ID: id, MakerID: m.id, Price: l.price, Qty: t})
		qty -= t
		m.qty -= t
		l.total -= t
		if m.qty == 0 {
			mid := m.id
			b.drop(m)
			b.emit(Event{Kind: Filled, ID: mid})
		}
	}
	switch {
	case qty == 0:
		b.emit(Event{Kind: Filled, ID: id})
	case tif == GTC && hasLimit:
		var o *order
		if n := len(b.spare); n > 0 {
			o = b.spare[n-1]
			b.spare = b.spare[:n-1]
		} else {
			o = new(order)
		}
		o.id, o.qty, o.side = id, qty, side
		b.sideOf(side).add(o, limit)
		b.orders[id] = o
		b.emit(Event{Kind: Rest, ID: id})
	default:
		b.emit(Event{Kind: Cancel, ID: id, Qty: qty})
	}
}
