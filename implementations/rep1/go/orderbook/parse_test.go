package orderbook

import (
	"slices"
	"testing"
)

func TestParse(t *testing.T) {
	in := "7\nLIMIT BUY BUY 105 3\nLIMIT x SELL 100 2 IOC\nLIMIT y SELL 105 2 FOK\n" +
		"MARKET m BUY 4\nCANCEL LIMIT\nREPLACE BUY 90 1\nBOOK"
	s, err := Parse([]byte(in)) // no trailing newline
	if err != nil {
		t.Fatal(err)
	}
	if want := []int64{90, 100, 105}; !slices.Equal(s.Prices, want) {
		t.Fatalf("prices = %v, want %v", s.Prices, want)
	}
	want := []Command{
		{Kind: KindLimit, ID: []byte("BUY"), Side: Buy, Price: 105, Qty: 3, rank: 2},
		{Kind: KindLimit, ID: []byte("x"), Side: Sell, Price: 100, Qty: 2, TIF: IOC, rank: 1},
		{Kind: KindLimit, ID: []byte("y"), Side: Sell, Price: 105, Qty: 2, TIF: FOK, rank: 2},
		{Kind: KindMarket, ID: []byte("m"), Side: Buy, Qty: 4},
		{Kind: KindCancel, ID: []byte("LIMIT")},
		{Kind: KindReplace, ID: []byte("BUY"), Price: 90, Qty: 1, rank: 0},
		{Kind: KindBook},
	}
	if len(s.Commands) != len(want) {
		t.Fatalf("got %d commands, want %d", len(s.Commands), len(want))
	}
	for i, w := range want {
		g := s.Commands[i]
		if g.Kind != w.Kind || g.Side != w.Side || g.TIF != w.TIF || g.Price != w.Price ||
			g.Qty != w.Qty || g.rank != w.rank || string(g.ID) != string(w.ID) {
			t.Errorf("command %d = %+v, want %+v", i, g, w)
		}
	}
}

func TestParseEmpty(t *testing.T) {
	for _, in := range []string{"0", "0\n"} {
		s, err := Parse([]byte(in))
		if err != nil || len(s.Commands) != 0 || len(s.Prices) != 0 {
			t.Errorf("Parse(%q) = %+v, %v", in, s, err)
		}
	}
}

func TestParseErrors(t *testing.T) {
	for _, in := range []string{
		"", "x\n", "1\n", "2\nBOOK\n", "1\nFOO\n", "1\nLIMIT a BUY 1\n",
		"1\nLIMIT a UP 1 1\n", "1\nLIMIT a BUY 1 1 GTC\n", "1\nLIMIT a BUY 1x 1\n",
		"1\nCANCEL\n", "1\nREPLACE a 1\n", "1\nMARKET a BUY\n",
	} {
		if _, err := Parse([]byte(in)); err == nil {
			t.Errorf("Parse(%q) succeeded, want error", in)
		}
	}
}
