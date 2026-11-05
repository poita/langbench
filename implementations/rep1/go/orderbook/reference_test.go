package orderbook

import (
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"testing"
)

// refOrder / refBook is a deliberately naive model of the specification:
// resting orders in plain slices, scanned linearly. It is only used to
// cross-check the real engine on random streams.
type refOrder struct {
	id         string
	side       Side
	price, qty int64
	seq        int
}

type refBook struct {
	orders []*refOrder
	seq    int
	out    strings.Builder
}

func (r *refBook) emit(f string, a ...any) { fmt.Fprintf(&r.out, f+"\n", a...) }

func (r *refBook) find(id string) int {
	for i, o := range r.orders {
		if o.id == id {
			return i
		}
	}
	return -1
}

func crossesRef(side Side, limit int64, hasLimit bool, o *refOrder) bool {
	if !hasLimit {
		return true
	}
	if side == Buy {
		return o.price <= limit
	}
	return o.price >= limit
}

func (r *refBook) match(id string, side Side, limit int64, hasLimit bool, qty int64) int64 {
	for qty > 0 {
		var best *refOrder
		for _, o := range r.orders {
			if o.side == side || !crossesRef(side, limit, hasLimit, o) {
				continue
			}
			if best == nil ||
				(side == Buy && (o.price < best.price || (o.price == best.price && o.seq < best.seq))) ||
				(side == Sell && (o.price > best.price || (o.price == best.price && o.seq < best.seq))) {
				best = o
			}
		}
		if best == nil {
			break
		}
		t := min(qty, best.qty)
		r.emit("TRADE %s %s %d %d", id, best.id, best.price, t)
		qty -= t
		best.qty -= t
		if best.qty == 0 {
			r.emit("FILLED %s", best.id)
			r.orders = r.orders[:r.find(best.id)+copy(r.orders[r.find(best.id):], r.orders[r.find(best.id)+1:])]
		}
	}
	return qty
}

func (r *refBook) limit(id string, side Side, price, qty int64, tif TimeInForce) {
	if tif == FOK {
		var avail int64
		for _, o := range r.orders {
			if o.side != side && crossesRef(side, price, true, o) {
				avail += o.qty
			}
		}
		if avail < qty {
			r.emit("REJECT %s", id)
			return
		}
	}
	rem := r.match(id, side, price, true, qty)
	switch {
	case rem == 0:
		r.emit("FILLED %s", id)
	case tif == GTC:
		r.seq++
		r.orders = append(r.orders, &refOrder{id, side, price, rem, r.seq})
		r.emit("REST %s", id)
	default:
		r.emit("CANCEL %s %d", id, rem)
	}
}

func (r *refBook) book() {
	for _, side := range []Side{Buy, Sell} {
		tot := map[int64][2]int64{}
		var ps []int64
		for _, o := range r.orders {
			if o.side == side {
				if _, ok := tot[o.price]; !ok {
					ps = append(ps, o.price)
				}
				v := tot[o.price]
				tot[o.price] = [2]int64{v[0] + o.qty, v[1] + 1}
			}
		}
		sort.Slice(ps, func(i, j int) bool { return (ps[i] > ps[j]) == (side == Buy) })
		for _, p := range ps {
			w := "BID"
			if side == Sell {
				w = "ASK"
			}
			r.emit("%s %d %d %d", w, p, tot[p][0], tot[p][1])
		}
	}
	r.emit("--")
}

func randomStream(rng *rand.Rand, n int) (string, string) {
	var in []string
	ref := &refBook{}
	var ids []string
	nextID := 0
	pick := func() string {
		if len(ids) > 0 && rng.Intn(6) != 0 {
			return ids[rng.Intn(len(ids))]
		}
		return fmt.Sprintf("ghost%d", rng.Intn(3))
	}
	price := func() int64 { return int64(95 + rng.Intn(11)) }
	qty := func() int64 {
		if rng.Intn(10) == 0 {
			return 1000000000 - int64(rng.Intn(3))
		}
		return int64(1 + rng.Intn(12))
	}
	sideName := func(s Side) string { return s.String() }
	for i := 0; i < n; i++ {
		switch k := rng.Intn(20); {
		case k < 9:
			nextID++
			id := fmt.Sprintf("o%d", nextID)
			ids = append(ids, id)
			s := Side(rng.Intn(2))
			p, q := price(), qty()
			tif := TimeInForce(0)
			if x := rng.Intn(8); x == 0 {
				tif = IOC
			} else if x == 1 {
				tif = FOK
			}
			line := fmt.Sprintf("LIMIT %s %s %d %d", id, sideName(s), p, q)
			if tif != GTC {
				line += " " + tif.String()
			}
			in = append(in, line)
			ref.limit(id, s, p, q, tif)
		case k < 11:
			nextID++
			id := fmt.Sprintf("o%d", nextID)
			ids = append(ids, id)
			s, q := Side(rng.Intn(2)), qty()
			in = append(in, fmt.Sprintf("MARKET %s %s %d", id, sideName(s), q))
			rem := ref.match(id, s, 0, false, q)
			if rem == 0 {
				ref.emit("FILLED %s", id)
			} else {
				ref.emit("CANCEL %s %d", id, rem)
			}
		case k < 14:
			id := pick()
			in = append(in, "CANCEL "+id)
			if j := ref.find(id); j >= 0 {
				ref.emit("CANCEL %s %d", id, ref.orders[j].qty)
				ref.orders = append(ref.orders[:j], ref.orders[j+1:]...)
			} else {
				ref.emit("REJECT %s", id)
			}
		case k < 18:
			id := pick()
			p, q := price(), qty()
			if rng.Intn(2) == 0 {
				q = int64(1 + rng.Intn(4))
			}
			in = append(in, fmt.Sprintf("REPLACE %s %d %d", id, p, q))
			j := ref.find(id)
			if j < 0 {
				ref.emit("REJECT %s", id)
				break
			}
			o := ref.orders[j]
			if p == o.price && q <= o.qty {
				o.qty = q
				ref.emit("REST %s", id)
				break
			}
			ref.orders = append(ref.orders[:j], ref.orders[j+1:]...)
			ref.limit(id, o.side, p, q, GTC)
		default:
			in = append(in, "BOOK")
			ref.book()
		}
	}
	return fmt.Sprintf("%d\n%s\n", len(in), strings.Join(in, "\n")), ref.out.String()
}

func TestAgainstReferenceModel(t *testing.T) {
	for seed := int64(0); seed < 300; seed++ {
		rng := rand.New(rand.NewSource(seed))
		input, want := randomStream(rng, 1+rng.Intn(300))
		got, err := Run([]byte(input))
		if err != nil {
			t.Fatalf("seed %d: %v", seed, err)
		}
		if string(got) != want {
			t.Fatalf("seed %d mismatch\ninput:\n%s\ngot:\n%s\nwant:\n%s", seed, input, got, want)
		}
	}
}
