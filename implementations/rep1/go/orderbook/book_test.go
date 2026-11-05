package orderbook

import (
	"errors"
	"strings"
	"testing"
)

// runText runs input through Run and compares the result with want (both
// given without common indentation).
func runText(t *testing.T, input, want string) {
	t.Helper()
	got, err := Run([]byte(input))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != want {
		t.Errorf("output mismatch\ngot:\n%s\nwant:\n%s", got, want)
	}
}

func lines(s ...string) string {
	if len(s) == 0 {
		return ""
	}
	return strings.Join(s, "\n") + "\n"
}

func TestSpecExample1(t *testing.T) {
	runText(t, lines("9",
		"LIMIT s1 SELL 101 5", "LIMIT s2 SELL 103 5", "LIMIT s3 SELL 102 5", "LIMIT s4 SELL 104 5",
		"LIMIT b1 BUY 103 12", "BOOK", "LIMIT b2 BUY 110 1", "LIMIT b3 BUY 103 9", "BOOK"),
		lines("REST s1", "REST s2", "REST s3", "REST s4",
			"TRADE b1 s1 101 5", "FILLED s1", "TRADE b1 s3 102 5", "FILLED s3",
			"TRADE b1 s2 103 2", "FILLED b1", "ASK 103 3 1", "ASK 104 5 1", "--",
			"TRADE b2 s2 103 1", "FILLED b2", "TRADE b3 s2 103 2", "FILLED s2", "REST b3",
			"BID 103 7 1", "ASK 104 5 1", "--"))
}

func TestSpecExample2(t *testing.T) {
	runText(t, lines("11",
		"LIMIT s1 SELL 100 5", "LIMIT s2 SELL 101 5", "LIMIT b1 BUY 100 8 IOC", "BOOK",
		"LIMIT b2 BUY 99 8 IOC", "LIMIT b3 BUY 101 5 IOC", "BOOK",
		"CANCEL b1", "REPLACE b1 100 1", "LIMIT s3 SELL 50 1 IOC", "BOOK"),
		lines("REST s1", "REST s2", "TRADE b1 s1 100 5", "FILLED s1", "CANCEL b1 3",
			"ASK 101 5 1", "--", "CANCEL b2 8", "TRADE b3 s2 101 5", "FILLED s2", "FILLED b3", "--",
			"REJECT b1", "REJECT b1", "CANCEL s3 1", "--"))
}

func TestSpecExample3(t *testing.T) {
	runText(t, lines("10",
		"LIMIT b1 BUY 100 10", "LIMIT s1 SELL 105 4", "LIMIT s2 SELL 106 4",
		"REPLACE b1 105 6", "BOOK", "REPLACE b1 110 20", "BOOK",
		"REPLACE b1 110 3", "CANCEL b1", "BOOK"),
		lines("REST b1", "REST s1", "REST s2",
			"TRADE b1 s1 105 4", "FILLED s1", "REST b1", "BID 105 2 1", "ASK 106 4 1", "--",
			"TRADE b1 s2 106 4", "FILLED s2", "REST b1", "BID 110 16 1", "--",
			"REST b1", "CANCEL b1 3", "--"))
}

func TestEmptyAndNoPrices(t *testing.T) {
	runText(t, "0\n", "")
	runText(t, lines("4", "MARKET m BUY 5", "CANCEL x", "REPLACE x 1 1", "BOOK"),
		lines("CANCEL m 5", "REJECT x", "REJECT x", "--"))
}

func TestFOK(t *testing.T) {
	runText(t, lines("7",
		"LIMIT s1 SELL 10 3", "LIMIT s2 SELL 11 3", "LIMIT s3 SELL 12 3",
		"LIMIT f1 BUY 11 7 FOK", // only 6 crossable
		"LIMIT f2 BUY 11 6 FOK",
		"LIMIT f3 BUY 12 4 FOK", // only s3's 3 left
		"BOOK"),
		lines("REST s1", "REST s2", "REST s3", "REJECT f1",
			"TRADE f2 s1 10 3", "FILLED s1", "TRADE f2 s2 11 3", "FILLED s2", "FILLED f2",
			"REJECT f3", "ASK 12 3 1", "--"))
}

func TestFOKRejectedWhenShort(t *testing.T) {
	runText(t, lines("5",
		"LIMIT s1 SELL 10 3", "LIMIT s2 SELL 12 3",
		"LIMIT f3 BUY 12 7 FOK", "LIMIT f4 SELL 10 1 FOK", "BOOK"),
		lines("REST s1", "REST s2", "REJECT f3", "REJECT f4", "ASK 10 3 1", "ASK 12 3 1", "--"))
}

func TestReplaceKeepsPriorityOnlyWhenPriceSameAndQtyNotIncreased(t *testing.T) {
	runText(t, lines("9",
		"LIMIT a BUY 10 5", "LIMIT b BUY 10 5",
		"REPLACE a 10 5", // same: keeps priority
		"LIMIT s1 SELL 10 1",
		"REPLACE a 10 6", // increase: goes behind b
		"LIMIT s2 SELL 10 1",
		"REPLACE b 10 1", // decrease: keeps place
		"BOOK", "CANCEL a"),
		lines("REST a", "REST b", "REST a",
			"TRADE s1 a 10 1", "FILLED s1", // a was still first
			"REST a",
			"TRADE s2 b 10 1", "FILLED s2", // b is first now
			"REST b", "BID 10 7 2", "--", "CANCEL a 6"))
}

func TestReplaceAggressiveSelfExcluded(t *testing.T) {
	// A re-entering order cannot trade against itself.
	runText(t, lines("3", "LIMIT a SELL 10 5", "REPLACE a 9 7", "BOOK"),
		lines("REST a", "REST a", "ASK 9 7 1", "--"))
}

func TestCancelThenReuseID(t *testing.T) {
	runText(t, lines("5", "LIMIT a BUY 5 2", "CANCEL a", "CANCEL a", "LIMIT a BUY 6 1", "BOOK"),
		lines("REST a", "CANCEL a 2", "REJECT a", "REST a", "BID 6 1 1", "--"))
}

func TestLargeQuantitiesUse64Bit(t *testing.T) {
	runText(t, lines("6",
		"LIMIT a BUY 5 1000000000", "LIMIT b BUY 5 1000000000", "LIMIT c BUY 5 1000000000",
		"LIMIT d BUY 5 1000000000", "LIMIT e BUY 5 1000000000", "BOOK"),
		lines("REST a", "REST b", "REST c", "REST d", "REST e", "BID 5 5000000000 5", "--"))
}

func TestBookAPI(t *testing.T) {
	b, err := NewBook([]int64{10, 20, 30})
	if err != nil {
		t.Fatal(err)
	}
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(b.Limit([]byte("a"), Buy, 10, 5, GTC))
	must(b.Limit([]byte("b"), Buy, 20, 2, GTC))
	must(b.Limit([]byte("s"), Sell, 30, 7, GTC))
	b.ResetOutput()
	if p, ok := b.Best(Buy); !ok || p != 20 {
		t.Errorf("Best(Buy) = %d, %v", p, ok)
	}
	if p, ok := b.Best(Sell); !ok || p != 30 {
		t.Errorf("Best(Sell) = %d, %v", p, ok)
	}
	var got []Level
	b.EachLevel(Buy, func(l Level) bool { got = append(got, l); return true })
	if len(got) != 2 || got[0] != (Level{20, 2, 1}) || got[1] != (Level{10, 5, 1}) {
		t.Errorf("levels = %+v", got)
	}
	n := 0
	b.EachLevel(Buy, func(Level) bool { n++; return false })
	if n != 1 {
		t.Errorf("EachLevel did not stop early")
	}
	if b.Len() != 3 {
		t.Errorf("Len = %d", b.Len())
	}
	must(b.Market([]byte("m"), Sell, 3))
	if string(b.Output()) != "TRADE m b 20 2\nFILLED b\nTRADE m a 10 1\nFILLED m\n" {
		t.Errorf("output = %q", b.Output())
	}
	if err := b.Execute(Command{Kind: KindBook}); err != nil {
		t.Fatal(err)
	}
}

func TestBookErrors(t *testing.T) {
	if _, err := NewBook([]int64{2, 2}); !errors.Is(err, ErrBadPrices) {
		t.Errorf("duplicate prices: %v", err)
	}
	if _, err := NewBook([]int64{0}); !errors.Is(err, ErrBadPrices) {
		t.Errorf("zero price: %v", err)
	}
	b, _ := NewBook([]int64{5})
	if err := b.Limit([]byte("a"), Buy, 6, 1, GTC); !errors.Is(err, ErrUnknownPrice) {
		t.Errorf("unknown price: %v", err)
	}
	if err := b.Limit([]byte("a"), Buy, 5, 0, GTC); !errors.Is(err, ErrInvalidQty) {
		t.Errorf("zero qty: %v", err)
	}
	if err := b.Limit([]byte("a"), Buy, 5, 1, GTC); err != nil {
		t.Fatal(err)
	}
	if err := b.Limit([]byte("a"), Buy, 5, 1, GTC); !errors.Is(err, ErrDuplicateID) {
		t.Errorf("duplicate id: %v", err)
	}
	if err := b.Execute(Command{Kind: 99}); !errors.Is(err, ErrBadCommand) {
		t.Errorf("bad kind: %v", err)
	}
	if len(b.Output()) != len("REST a\n") {
		t.Errorf("failed calls must not emit events, output = %q", b.Output())
	}
}
