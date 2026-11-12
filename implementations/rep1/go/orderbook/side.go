package orderbook

// bookSide is one side of the book: an ordered set of price levels.
type bookSide struct {
	isBid  bool
	root   *level
	byPx   map[uint64]*level
	best   *level // best level, or nil when the side is empty
	seed   uint32 // xorshift state for treap priorities
	spares []*level
}

func newSide(isBid bool, seed uint32) *bookSide {
	return &bookSide{isBid: isBid, byPx: make(map[uint64]*level), seed: seed}
}

func (s *bookSide) nextPrio() uint32 {
	x := s.seed
	x ^= x << 13
	x ^= x >> 17
	x ^= x << 5
	s.seed = x
	return x
}

// crosses reports whether a taker with the given limit price trades against a
// resting level at levelPrice on this side.
func (s *bookSide) crosses(levelPrice, limit uint64) bool {
	if s.isBid {
		return levelPrice >= limit // incoming SELL
	}
	return levelPrice <= limit // incoming BUY
}

func (s *bookSide) betterThan(a, b uint64) bool {
	if s.isBid {
		return a > b
	}
	return a < b
}

func (s *bookSide) recomputeBest() {
	if s.isBid {
		s.best = treeMax(s.root)
	} else {
		s.best = treeMin(s.root)
	}
}

// add appends o to the back of the queue at price, creating the level if
// necessary.
func (s *bookSide) add(o *order, price uint64) {
	l := s.byPx[price]
	if l == nil {
		if n := len(s.spares); n > 0 {
			l = s.spares[n-1]
			s.spares = s.spares[:n-1]
		} else {
			l = new(level)
		}
		l.price = price
		l.prio = s.nextPrio()
		s.byPx[price] = l
		s.root = treeInsert(s.root, l)
		if s.best == nil || s.betterThan(price, s.best.price) {
			s.best = l
		}
	}
	l.pushBack(o)
}

// remove takes o out of its level, dropping the level if it becomes empty.
func (s *bookSide) remove(o *order) {
	l := o.lvl
	l.unlink(o)
	o.lvl = nil
	if l.count > 0 {
		return
	}
	delete(s.byPx, l.price)
	s.root = treeDelete(s.root, l.price)
	if s.best == l {
		s.recomputeBest()
	}
	*l = level{}
	s.spares = append(s.spares, l)
}

// each visits levels from best to worst until fn returns false.
func (s *bookSide) each(fn func(*level) bool) {
	treeWalk(s.root, s.isBid, fn)
}

func (s *bookSide) levels() []Level {
	out := make([]Level, 0, len(s.byPx))
	s.each(func(l *level) bool {
		out = append(out, Level{Price: l.price, Qty: l.total, Orders: l.count})
		return true
	})
	return out
}
