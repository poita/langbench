package orderbook

import (
	"math"
	"slices"
	"strconv"
)

// level is the FIFO queue of orders at one price.
type level struct {
	head, tail int32 // arena indices, -1 when empty
	total      int64 // sum of remaining quantities
	count      int32 // number of orders
}

// order is an arena record for a resting order.
type order struct {
	id         string
	qty        int64 // remaining quantity
	rank       int32 // price rank
	side       Side
	prev, next int32 // FIFO neighbours within the level (next doubles as the free-list link)
}

// bookSide is one side of the book: a dense level array plus its index tree.
type bookSide struct {
	levels []level
	tree   segTree
}

// refresh republishes level r to the tree.
func (s *bookSide) refresh(r int) {
	lv := &s.levels[r]
	s.tree.set(r, lv.total, lv.count > 0)
}

// Book is a limit order book over a fixed table of prices. Create one with
// [NewBook]. Methods append their events to an internal output buffer; see
// [Book.Output].
type Book struct {
	prices []int64
	sides  [2]bookSide
	orders []order
	free   int32 // head of the arena free list, -1 if none
	ids    map[string]int32
	out    []byte
	prefix []byte // scratch: "TRADE <taker-id> "
}

// NewBook returns an empty book that accepts exactly the given prices, which
// must be positive and strictly ascending. The slice is retained and must
// not be modified afterwards.
func NewBook(prices []int64) (*Book, error) {
	for i, p := range prices {
		if p <= 0 || (i > 0 && p <= prices[i-1]) {
			return nil, ErrBadPrices
		}
	}
	b := &Book{prices: prices, free: -1, ids: make(map[string]int32)}
	for s := range b.sides {
		lv := make([]level, len(prices))
		for i := range lv {
			lv[i].head, lv[i].tail = -1, -1
		}
		b.sides[s] = bookSide{levels: lv, tree: newSegTree(len(prices))}
	}
	return b, nil
}

// Reserve pre-sizes the order arena, id map and output buffer for roughly n
// commands. It is only a hint and never changes behaviour.
func (b *Book) Reserve(n int) {
	resting := min(n, 1<<16)
	if cap(b.orders) < resting {
		b.orders = slices.Grow(b.orders, resting)
	}
	if len(b.ids) == 0 {
		b.ids = make(map[string]int32, resting)
	}
	b.out = slices.Grow(b.out, min(n, 1<<22)*24)
}

// Output returns the events appended so far. The slice is valid until the
// next call that appends or resets.
func (b *Book) Output() []byte { return b.out }

// ResetOutput discards the buffered events, keeping the book's state.
func (b *Book) ResetOutput() { b.out = b.out[:0] }

// Len returns the number of resting orders.
func (b *Book) Len() int { return len(b.ids) }

// rankOf returns the rank of price in the table.
func (b *Book) rankOf(price int64) (int32, error) {
	i, ok := slices.BinarySearch(b.prices, price)
	if !ok {
		return 0, ErrUnknownPrice
	}
	return int32(i), nil
}

// Best returns the best price on the side (highest bid, lowest ask).
func (b *Book) Best(side Side) (price int64, ok bool) {
	t := &b.sides[side].tree
	r := t.lowest()
	if side == Buy {
		r = t.highest()
	}
	if r < 0 {
		return 0, false
	}
	return b.prices[r], true
}

// EachLevel calls fn for every non-empty level of the side, best first
// (descending prices for Buy, ascending for Sell), until fn returns false.
func (b *Book) EachLevel(side Side, fn func(Level) bool) {
	s := &b.sides[side]
	var r int
	if side == Buy {
		r = s.tree.highest()
	} else {
		r = s.tree.lowest()
	}
	for r >= 0 {
		lv := &s.levels[r]
		if !fn(Level{Price: b.prices[r], Qty: lv.total, Orders: int(lv.count)}) {
			return
		}
		if side == Buy {
			r = s.tree.prev(r - 1)
		} else {
			r = s.tree.next(r + 1)
		}
	}
}

// Snapshot appends a BOOK listing (all bid levels best first, all ask levels
// best first, then "--") to the output.
func (b *Book) Snapshot() {
	for _, side := range [2]Side{Buy, Sell} {
		word := "BID "
		if side == Sell {
			word = "ASK "
		}
		b.EachLevel(side, func(l Level) bool {
			b.out = append(b.out, word...)
			b.out = strconv.AppendInt(b.out, l.Price, 10)
			b.out = append(b.out, ' ')
			b.out = strconv.AppendInt(b.out, l.Qty, 10)
			b.out = append(b.out, ' ')
			b.out = strconv.AppendInt(b.out, int64(l.Orders), 10)
			b.out = append(b.out, '\n')
			return true
		})
	}
	b.out = append(b.out, "--\n"...)
}

// Execute runs one parsed command against the book.
func (b *Book) Execute(c Command) error {
	switch c.Kind {
	case KindLimit:
		return b.Limit(c.ID, c.Side, c.Price, c.Qty, c.TIF)
	case KindMarket:
		return b.Market(c.ID, c.Side, c.Qty)
	case KindCancel:
		b.Cancel(c.ID)
	case KindReplace:
		return b.Replace(c.ID, c.Price, c.Qty)
	case KindBook:
		b.Snapshot()
	default:
		return ErrBadCommand
	}
	return nil
}

// execRanked runs a command whose price rank was precomputed by the parser.
func (b *Book) execRanked(c *Command) error {
	switch c.Kind {
	case KindLimit:
		return b.limit(c.ID, c.Side, c.rank, c.Qty, c.TIF)
	case KindMarket:
		return b.Market(c.ID, c.Side, c.Qty)
	case KindCancel:
		b.Cancel(c.ID)
	case KindReplace:
		return b.replace(c.ID, c.rank, c.Qty)
	case KindBook:
		b.Snapshot()
	default:
		return ErrBadCommand
	}
	return nil
}

// Limit submits a limit order. Events are appended to the output: TRADE and
// FILLED lines for the makers it hits, then FILLED, REST, CANCEL or REJECT
// for the order itself, according to tif. Returns ErrUnknownPrice,
// ErrInvalidQty or ErrDuplicateID (with nothing appended) for invalid input.
func (b *Book) Limit(id []byte, side Side, price, qty int64, tif TimeInForce) error {
	rank, err := b.rankOf(price)
	if err != nil {
		return err
	}
	return b.limit(id, side, rank, qty, tif)
}

func (b *Book) limit(id []byte, side Side, rank int32, qty int64, tif TimeInForce) error {
	if qty <= 0 {
		return ErrInvalidQty
	}
	if tif == GTC {
		if _, dup := b.ids[string(id)]; dup {
			return ErrDuplicateID
		}
	}
	if tif == FOK && b.available(side, rank) < qty {
		b.appendLine("REJECT ", id)
		return nil
	}
	b.setPrefix(id)
	rem := b.match(side, rank, qty)
	switch {
	case rem == 0:
		b.appendLine("FILLED ", id)
	case tif == GTC:
		idx := b.alloc(string(id), side)
		b.orders[idx].qty = rem
		b.orders[idx].rank = rank
		b.link(idx)
		b.appendLine("REST ", id)
	default:
		b.appendCancel(id, rem)
	}
	return nil
}

// Market submits a market order. It never rests: the unfilled remainder, if
// any, is reported as CANCEL.
func (b *Book) Market(id []byte, side Side, qty int64) error {
	if qty <= 0 {
		return ErrInvalidQty
	}
	limit := int32(0) // a sell crosses every rank >= 0
	if side == Buy {
		limit = math.MaxInt32 // a buy crosses every rank <= MaxInt32
	}
	b.setPrefix(id)
	if rem := b.match(side, limit, qty); rem == 0 {
		b.appendLine("FILLED ", id)
	} else {
		b.appendCancel(id, rem)
	}
	return nil
}

// Cancel removes a resting order, printing CANCEL with its remaining
// quantity, or REJECT if id is not resting.
func (b *Book) Cancel(id []byte) {
	idx, ok := b.ids[string(id)]
	if !ok {
		b.appendLine("REJECT ", id)
		return
	}
	o := &b.orders[idx]
	b.appendCancel(id, o.qty)
	b.unlink(idx)
	delete(b.ids, o.id)
	b.release(idx)
}

// Replace modifies a resting order: price becomes price and the remaining
// quantity becomes qty. An unchanged price with a non-increased quantity
// keeps queue priority; anything else re-enters the order as a new limit
// order on its original side. Prints REJECT if id is not resting.
func (b *Book) Replace(id []byte, price, qty int64) error {
	rank, err := b.rankOf(price)
	if err != nil {
		return err
	}
	return b.replace(id, rank, qty)
}

func (b *Book) replace(id []byte, rank int32, qty int64) error {
	if qty <= 0 {
		return ErrInvalidQty
	}
	idx, ok := b.ids[string(id)]
	if !ok {
		b.appendLine("REJECT ", id)
		return nil
	}
	o := &b.orders[idx]
	s := &b.sides[o.side]
	if rank == o.rank && qty <= o.qty {
		s.levels[rank].total -= o.qty - qty
		o.qty = qty
		s.refresh(int(rank))
		b.appendLine("REST ", id)
		return nil
	}
	side := o.side
	b.unlink(idx)
	b.setPrefix(id)
	rem := b.match(side, rank, qty)
	o = &b.orders[idx] // match never grows the arena, but stay safe
	if rem == 0 {
		b.appendLine("FILLED ", id)
		delete(b.ids, o.id)
		b.release(idx)
		return nil
	}
	o.qty = rem
	o.rank = rank
	b.link(idx)
	b.appendLine("REST ", id)
	return nil
}

// available returns the resting quantity an incoming order on side with
// limit rank would cross.
func (b *Book) available(side Side, rank int32) int64 {
	if side == Buy {
		return b.sides[Sell].tree.prefixSum(int(rank))
	}
	return b.sides[Buy].tree.suffixSum(int(rank))
}

// match fills an incoming order of the given side and quantity against the
// opposite side while the best level crosses limit (a rank: a buy crosses
// ranks <= limit, a sell ranks >= limit). b.prefix must hold the TRADE line
// prefix for the taker. It returns the unfilled quantity.
func (b *Book) match(side Side, limit int32, qty int64) int64 {
	opp := &b.sides[1-side]
	for qty > 0 {
		var r int
		if side == Buy {
			r = opp.tree.lowest()
			if r < 0 || r > int(limit) {
				break
			}
		} else {
			r = opp.tree.highest()
			if r < 0 || r < int(limit) {
				break
			}
		}
		lv := &opp.levels[r]
		price := b.prices[r]
		for qty > 0 && lv.head >= 0 {
			idx := lv.head
			o := &b.orders[idx]
			t := min(qty, o.qty)
			b.out = append(b.out, b.prefix...)
			b.out = append(b.out, o.id...)
			b.out = append(b.out, ' ')
			b.out = strconv.AppendInt(b.out, price, 10)
			b.out = append(b.out, ' ')
			b.out = strconv.AppendInt(b.out, t, 10)
			b.out = append(b.out, '\n')
			qty -= t
			o.qty -= t
			lv.total -= t
			if o.qty == 0 {
				b.out = append(b.out, "FILLED "...)
				b.out = append(b.out, o.id...)
				b.out = append(b.out, '\n')
				lv.head = o.next
				if lv.head >= 0 {
					b.orders[lv.head].prev = -1
				} else {
					lv.tail = -1
				}
				lv.count--
				delete(b.ids, o.id)
				b.release(idx)
			}
		}
		opp.refresh(r)
	}
	return qty
}

// alloc takes an arena record for a new resting order and registers its id.
func (b *Book) alloc(id string, side Side) int32 {
	var idx int32
	if b.free >= 0 {
		idx = b.free
		b.free = b.orders[idx].next
		b.orders[idx] = order{id: id, side: side}
	} else {
		idx = int32(len(b.orders))
		b.orders = append(b.orders, order{id: id, side: side})
	}
	b.ids[id] = idx
	return idx
}

// release returns an arena record to the free list. The caller removes the
// id from the map.
func (b *Book) release(idx int32) {
	b.orders[idx] = order{next: b.free}
	b.free = idx
}

// link appends order idx to the back of its level's queue.
func (b *Book) link(idx int32) {
	o := &b.orders[idx]
	s := &b.sides[o.side]
	lv := &s.levels[o.rank]
	o.prev, o.next = lv.tail, -1
	if lv.tail >= 0 {
		b.orders[lv.tail].next = idx
	} else {
		lv.head = idx
	}
	lv.tail = idx
	lv.total += o.qty
	lv.count++
	s.refresh(int(o.rank))
}

// unlink removes order idx from its level's queue (the record stays
// allocated and registered).
func (b *Book) unlink(idx int32) {
	o := &b.orders[idx]
	s := &b.sides[o.side]
	lv := &s.levels[o.rank]
	if o.prev >= 0 {
		b.orders[o.prev].next = o.next
	} else {
		lv.head = o.next
	}
	if o.next >= 0 {
		b.orders[o.next].prev = o.prev
	} else {
		lv.tail = o.prev
	}
	lv.total -= o.qty
	lv.count--
	s.refresh(int(o.rank))
}

func (b *Book) setPrefix(id []byte) {
	b.prefix = append(append(append(b.prefix[:0], "TRADE "...), id...), ' ')
}

func (b *Book) appendLine(word string, id []byte) {
	b.out = append(b.out, word...)
	b.out = append(b.out, id...)
	b.out = append(b.out, '\n')
}

func (b *Book) appendCancel(id []byte, rem int64) {
	b.out = append(b.out, "CANCEL "...)
	b.out = append(b.out, id...)
	b.out = append(b.out, ' ')
	b.out = strconv.AppendInt(b.out, rem, 10)
	b.out = append(b.out, '\n')
}
