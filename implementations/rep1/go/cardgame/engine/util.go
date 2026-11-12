package engine

import (
	"io"
	"sort"
	"strconv"
	"strings"

	"github.com/spiremark/cardgame/prng"
)

func itoa(n int) string { return strconv.Itoa(n) }

func oidS(o *Obj) string { return "#" + strconv.Itoa(o.OID) }

func signed(n int) string {
	if n >= 0 {
		return "+" + strconv.Itoa(n)
	}
	return strconv.Itoa(n)
}

// emit writes one numbered event line.
func (g *Game) emit(name string, fields ...string) {
	g.seq++
	b := g.scratch[:0]
	b = strconv.AppendInt(b, int64(g.seq), 10)
	b = append(b, ' ')
	b = append(b, name...)
	for _, f := range fields {
		b = append(b, ' ')
		b = append(b, f...)
	}
	b = append(b, '\n')
	g.scratch = b
	_, _ = g.out.Write(b)
}

func (g *Game) writeLine(parts ...string) {
	_, _ = io.WriteString(g.out, strings.Join(parts, " ")+"\n")
}

func sortObjs(os []*Obj) {
	sort.SliceStable(os, func(i, j int) bool {
		if os[i].ts != os[j].ts {
			return os[i].ts < os[j].ts
		}
		return os[i].OID < os[j].OID
	})
}

func (g *Game) touch() { g.dirty = true }

func (g *Game) newTS() int  { t := g.nextTS; g.nextTS++; return t }
func (g *Game) newEID() int { t := g.nextEID; g.nextEID++; return t }

// Lookup returns the object with the given oid.
func (g *Game) Lookup(oid int) *Obj {
	if oid <= 0 || oid >= len(g.byOID) {
		return nil
	}
	return g.byOID[oid]
}

func (g *Game) rngInit(seed uint64) { g.rng = prng.New(seed) }
