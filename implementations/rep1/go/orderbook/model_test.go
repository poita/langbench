package orderbook_test

import (
	"fmt"
	"math/rand/v2"
	"slices"
	"testing"

	"github.com/peteralexander/orderbook"
)

// model is a deliberately naive reference implementation: a flat slice of
// resting orders scanned linearly, written straight from the specification.
type model struct {
	orders []mOrder // in arrival order at their level (global sequence)
	seq    int
	out    []string
}

type mOrder struct {
	id    string
	side  orderbook.Side
	price uint64
	qty   uint64
	seq   int
}

func (m *model) find(id string) int {
	return slices.IndexFunc(m.orders, func(o mOrder) bool { return o.id == id })
}

func (m *model) emit(f string, a ...any) { m.out = append(m.out, fmt.Sprintf(f, a...)) }

func crosses(side orderbook.Side, limit uint64, hasLimit bool, p uint64) bool {
	if !hasLimit {
		return true
	}
	if side == orderbook.Buy {
		return p <= limit
	}
	return p >= limit
}

// bestIdx returns the index of the order a taker on side would trade with.
func (m *model) bestIdx(side orderbook.Side) int {
	best := -1
	for i, o := range m.orders {
		if o.side == side {
			continue
		}
		if best < 0 {
			best = i
			continue
		}
		b := m.orders[best]
		better := o.price < b.price
		if side == orderbook.Sell { // maker is a bid: higher is better
			better = o.price > b.price
		}
		if better || (o.price == b.price && o.seq < b.seq) {
			best = i
		}
	}
	return best
}

func (m *model) match(id string, side orderbook.Side, limit uint64, hasLimit bool, qty uint64) uint64 {
	for qty > 0 {
		i := m.bestIdx(side)
		if i < 0 || !crosses(side, limit, hasLimit, m.orders[i].price) {
			break
		}
		mk := &m.orders[i]
		t := min(qty, mk.qty)
		m.emit("TRADE %s %s %d %d", id, mk.id, mk.price, t)
		qty -= t
		mk.qty -= t
		if mk.qty == 0 {
			m.emit("FILLED %s", mk.id)
			m.orders = slices.Delete(m.orders, i, i+1)
		}
	}
	return qty
}

func (m *model) rest(id string, side orderbook.Side, price, qty uint64) {
	m.seq++
	m.orders = append(m.orders, mOrder{id, side, price, qty, m.seq})
	m.emit("REST %s", id)
}

func (m *model) limit(id string, side orderbook.Side, price, qty uint64, tif orderbook.TimeInForce) {
	if tif == orderbook.FOK {
		var avail uint64
		for _, o := range m.orders {
			if o.side != side && crosses(side, price, true, o.price) {
				avail += o.qty
			}
		}
		if avail < qty {
			m.emit("REJECT %s", id)
			return
		}
	}
	rem := m.match(id, side, price, true, qty)
	switch {
	case rem == 0:
		m.emit("FILLED %s", id)
	case tif == orderbook.GTC:
		m.rest(id, side, price, rem)
	default:
		m.emit("CANCEL %s %d", id, rem)
	}
}

func (m *model) market(id string, side orderbook.Side, qty uint64) {
	if rem := m.match(id, side, 0, false, qty); rem == 0 {
		m.emit("FILLED %s", id)
	} else {
		m.emit("CANCEL %s %d", id, rem)
	}
}

func (m *model) cancel(id string) {
	i := m.find(id)
	if i < 0 {
		m.emit("REJECT %s", id)
		return
	}
	m.emit("CANCEL %s %d", id, m.orders[i].qty)
	m.orders = slices.Delete(m.orders, i, i+1)
}

func (m *model) replace(id string, price, qty uint64) {
	i := m.find(id)
	if i < 0 {
		m.emit("REJECT %s", id)
		return
	}
	o := m.orders[i]
	if price == o.price && qty <= o.qty {
		m.orders[i].qty = qty
		m.emit("REST %s", id)
		return
	}
	m.orders = slices.Delete(m.orders, i, i+1)
	m.limit(id, o.side, price, qty, orderbook.GTC)
}

func (m *model) book() {
	for _, side := range []orderbook.Side{orderbook.Buy, orderbook.Sell} {
		type agg struct{ qty, n uint64 }
		lv := map[uint64]*agg{}
		var prices []uint64
		for _, o := range m.orders {
			if o.side != side {
				continue
			}
			a := lv[o.price]
			if a == nil {
				a = &agg{}
				lv[o.price] = a
				prices = append(prices, o.price)
			}
			a.qty += o.qty
			a.n++
		}
		slices.Sort(prices)
		if side == orderbook.Buy {
			slices.Reverse(prices)
		}
		for _, p := range prices {
			name := "BID"
			if side == orderbook.Sell {
				name = "ASK"
			}
			m.emit("%s %d %d %d", name, p, lv[p].qty, lv[p].n)
		}
	}
	m.emit("--")
}

// TestRandomAgainstModel drives the Book and the naive model with the same
// random command stream and compares every event.
func TestRandomAgainstModel(t *testing.T) {
	for seed := uint64(1); seed <= 20; seed++ {
		rng := rand.New(rand.NewPCG(seed, 99))
		b := orderbook.New()
		m := &model{}
		var ids []string
		pricesSpan := uint64(5 + rng.IntN(60))
		maxQty := uint64(1 + rng.IntN(20))
		for step := 0; step < 3000; step++ {
			m.out = m.out[:0]
			side := orderbook.Side(rng.IntN(2))
			price := 100 + uint64(rng.Uint64N(pricesSpan))
			qty := 1 + rng.Uint64N(maxQty)
			pick := func() string {
				if len(ids) == 0 || rng.IntN(10) == 0 {
					return "unknown"
				}
				return ids[rng.IntN(len(ids))]
			}
			var cmd orderbook.Command
			switch r := rng.IntN(100); {
			case r < 45:
				id := fmt.Sprint("o", step)
				ids = append(ids, id)
				cmd = orderbook.Command{Kind: orderbook.CmdLimit, ID: id, Side: side, Price: price, Qty: qty}
				m.limit(id, side, price, qty, orderbook.GTC)
			case r < 55:
				id := fmt.Sprint("o", step)
				ids = append(ids, id)
				tif := orderbook.IOC
				if rng.IntN(2) == 0 {
					tif = orderbook.FOK
				}
				cmd = orderbook.Command{Kind: orderbook.CmdLimit, ID: id, Side: side, Price: price, Qty: qty, TIF: tif}
				m.limit(id, side, price, qty, tif)
			case r < 62:
				id := fmt.Sprint("o", step)
				ids = append(ids, id)
				cmd = orderbook.Command{Kind: orderbook.CmdMarket, ID: id, Side: side, Qty: qty}
				m.market(id, side, qty)
			case r < 77:
				id := pick()
				cmd = orderbook.Command{Kind: orderbook.CmdCancel, ID: id}
				m.cancel(id)
			case r < 95:
				id := pick()
				cmd = orderbook.Command{Kind: orderbook.CmdReplace, ID: id, Price: price, Qty: qty}
				m.replace(id, price, qty)
			default:
				cmd = orderbook.Command{Kind: orderbook.CmdBook}
				m.book()
			}
			var got []string
			for _, e := range b.Execute(cmd) {
				got = append(got, e.String())
			}
			if !slices.Equal(got, m.out) {
				t.Fatalf("seed %d step %d cmd %+v:\ngot  %q\nwant %q", seed, step, cmd, got, m.out)
			}
		}
		// Final state must agree too.
		m.out = m.out[:0]
		m.book()
		var got []string
		for _, e := range b.Snapshot() {
			got = append(got, e.String())
		}
		if !slices.Equal(got, m.out) {
			t.Fatalf("seed %d: final book differs", seed)
		}
		if b.Len() != len(m.orders) {
			t.Fatalf("seed %d: Len=%d want %d", seed, b.Len(), len(m.orders))
		}
	}
}

func BenchmarkMixedWorkload(b *testing.B) {
	rng := rand.New(rand.NewPCG(7, 7))
	bk := orderbook.New()
	for i := 0; i < b.N; i++ {
		id := fmt.Sprint("o", i)
		side := orderbook.Side(rng.IntN(2))
		price := 10000 + rng.Uint64N(2000)
		if side == orderbook.Sell {
			price += 1000
		}
		bk.Limit(id, side, price, 1+rng.Uint64N(100), orderbook.GTC)
	}
}
