package orderbook_test

import (
	"fmt"
	"strings"
	"testing"

	"github.com/peteralexander/orderbook"
)

// lines renders events one per line, the way the CLI prints them.
func lines(evs []orderbook.Event) string {
	var sb strings.Builder
	for _, e := range evs {
		sb.WriteString(e.String())
		sb.WriteByte('\n')
	}
	return sb.String()
}

func expect(t *testing.T, got []orderbook.Event, want ...string) {
	t.Helper()
	g := strings.TrimSuffix(lines(got), "\n")
	w := strings.Join(want, "\n")
	if g != w {
		t.Errorf("events:\n%s\nwant:\n%s", g, w)
	}
}

func TestLimitRestsAndFills(t *testing.T) {
	b := orderbook.New()
	expect(t, b.Limit("s1", orderbook.Sell, 101, 5, orderbook.GTC), "REST s1")
	expect(t, b.Limit("b1", orderbook.Buy, 99, 5, orderbook.GTC), "REST b1")
	expect(t, b.Limit("b2", orderbook.Buy, 105, 8, orderbook.GTC),
		"TRADE b2 s1 101 5", "FILLED s1", "REST b2")
	if b.Len() != 2 || !b.Has("b2") || b.Has("s1") {
		t.Errorf("Len=%d Has(b2)=%v Has(s1)=%v", b.Len(), b.Has("b2"), b.Has("s1"))
	}
	expect(t, b.Limit("s2", orderbook.Sell, 99, 10, orderbook.GTC),
		"TRADE s2 b2 105 3", "FILLED b2", "TRADE s2 b1 99 5", "FILLED b1", "REST s2")
}

func TestPriceTimePriority(t *testing.T) {
	b := orderbook.New()
	for _, id := range []string{"b1", "b2", "b3"} {
		b.Limit(id, orderbook.Buy, 100, 5, orderbook.GTC)
	}
	b.Limit("b4", orderbook.Buy, 101, 2, orderbook.GTC)
	expect(t, b.Limit("s1", orderbook.Sell, 100, 7, orderbook.GTC),
		"TRADE s1 b4 101 2", "FILLED b4", "TRADE s1 b1 100 5", "FILLED b1", "FILLED s1")
	expect(t, b.Limit("s2", orderbook.Sell, 100, 6, orderbook.GTC),
		"TRADE s2 b2 100 5", "FILLED b2", "TRADE s2 b3 100 1", "FILLED s2")
	if got := b.Bids(); len(got) != 1 || got[0] != (orderbook.Level{Price: 100, Qty: 4, Orders: 1}) {
		t.Errorf("Bids = %+v", got)
	}
}

func TestIOC(t *testing.T) {
	b := orderbook.New()
	b.Limit("s1", orderbook.Sell, 100, 5, orderbook.GTC)
	expect(t, b.Limit("b1", orderbook.Buy, 100, 8, orderbook.IOC),
		"TRADE b1 s1 100 5", "FILLED s1", "CANCEL b1 3")
	expect(t, b.Limit("b2", orderbook.Buy, 100, 8, orderbook.IOC), "CANCEL b2 8")
	if b.Len() != 0 {
		t.Errorf("IOC must not rest, Len=%d", b.Len())
	}
}

func TestFOK(t *testing.T) {
	b := orderbook.New()
	b.Limit("s1", orderbook.Sell, 100, 5, orderbook.GTC)
	b.Limit("s2", orderbook.Sell, 101, 5, orderbook.GTC)
	b.Limit("s3", orderbook.Sell, 105, 100, orderbook.GTC)
	expect(t, b.Limit("f1", orderbook.Buy, 101, 11, orderbook.FOK), "REJECT f1")
	if b.Len() != 3 {
		t.Fatal("rejected FOK must not change the book")
	}
	expect(t, b.Limit("f2", orderbook.Buy, 101, 10, orderbook.FOK),
		"TRADE f2 s1 100 5", "FILLED s1", "TRADE f2 s2 101 5", "FILLED s2", "FILLED f2")
	expect(t, b.Limit("f3", orderbook.Sell, 1, 1, orderbook.FOK), "REJECT f3")
	if b.Has("f1") || b.Has("f2") {
		t.Error("FOK orders must not rest")
	}
}

func TestMarket(t *testing.T) {
	b := orderbook.New()
	expect(t, b.Market("m0", orderbook.Buy, 4), "CANCEL m0 4")
	b.Limit("s1", orderbook.Sell, 100, 3, orderbook.GTC)
	b.Limit("s2", orderbook.Sell, 900000000, 3, orderbook.GTC)
	expect(t, b.Market("m1", orderbook.Buy, 5),
		"TRADE m1 s1 100 3", "FILLED s1", "TRADE m1 s2 900000000 2", "FILLED m1")
	expect(t, b.Market("m2", orderbook.Buy, 5), "TRADE m2 s2 900000000 1", "FILLED s2", "CANCEL m2 4")
}

func TestCancel(t *testing.T) {
	b := orderbook.New()
	b.Limit("b1", orderbook.Buy, 100, 5, orderbook.GTC)
	b.Limit("b2", orderbook.Buy, 100, 6, orderbook.GTC)
	b.Limit("b3", orderbook.Buy, 100, 7, orderbook.GTC)
	expect(t, b.Cancel("b2"), "CANCEL b2 6")
	expect(t, b.Cancel("b2"), "REJECT b2")
	expect(t, b.Cancel("nope"), "REJECT nope")
	if got := b.Bids(); got[0].Qty != 12 || got[0].Orders != 2 {
		t.Errorf("level after cancel = %+v", got[0])
	}
	expect(t, b.Limit("s1", orderbook.Sell, 100, 6, orderbook.GTC),
		"TRADE s1 b1 100 5", "FILLED b1", "TRADE s1 b3 100 1", "FILLED s1")
	expect(t, b.Cancel("b1"), "REJECT b1") // already filled
	expect(t, b.Cancel("b3"), "CANCEL b3 6")
	if len(b.Bids()) != 0 {
		t.Error("empty level should disappear")
	}
}

func TestReplace(t *testing.T) {
	b := orderbook.New()
	b.Limit("b1", orderbook.Buy, 100, 10, orderbook.GTC)
	b.Limit("b2", orderbook.Buy, 100, 10, orderbook.GTC)
	// Quantity decrease keeps priority.
	expect(t, b.Replace("b1", 100, 4), "REST b1")
	expect(t, b.Limit("s1", orderbook.Sell, 100, 1, orderbook.GTC), "TRADE s1 b1 100 1", "FILLED s1")
	// Quantity increase loses priority: b1 goes behind b2.
	expect(t, b.Replace("b1", 100, 5), "REST b1")
	expect(t, b.Limit("s2", orderbook.Sell, 100, 1, orderbook.GTC), "TRADE s2 b2 100 1", "FILLED s2")
	// Equal quantity keeps priority.
	expect(t, b.Replace("b2", 100, 9), "REST b2")
	expect(t, b.Limit("s3", orderbook.Sell, 100, 1, orderbook.GTC), "TRADE s3 b2 100 1", "FILLED s3")
	// Price change to the same level loses priority even with less quantity.
	b.Limit("b3", orderbook.Buy, 99, 1, orderbook.GTC)
	expect(t, b.Replace("b3", 100, 1), "REST b3")
	if got := b.Bids(); len(got) != 1 || got[0].Orders != 3 {
		t.Errorf("Bids = %+v", got)
	}
	expect(t, b.Replace("ghost", 1, 1), "REJECT ghost")
	// Aggressive replace trades against later arrivals.
	b2 := orderbook.New()
	b2.Limit("b1", orderbook.Buy, 100, 10, orderbook.GTC)
	b2.Limit("s1", orderbook.Sell, 105, 4, orderbook.GTC)
	expect(t, b2.Replace("b1", 105, 6), "TRADE b1 s1 105 4", "FILLED s1", "REST b1")
	expect(t, b2.Replace("b1", 106, 2), "REST b1")
	expect(t, b2.Cancel("b1"), "CANCEL b1 2")
	// A replace that fully fills ends the order.
	b2.Limit("s2", orderbook.Sell, 200, 1, orderbook.GTC)
	b2.Limit("b9", orderbook.Buy, 1, 1, orderbook.GTC)
	expect(t, b2.Replace("b9", 200, 1), "TRADE b9 s2 200 1", "FILLED s2", "FILLED b9")
	expect(t, b2.Cancel("b9"), "REJECT b9")
}

func TestSnapshotAndTotalsBeyond32Bits(t *testing.T) {
	b := orderbook.New()
	if got := b.Snapshot(); len(got) != 1 || got[0].Kind != orderbook.EndBook {
		t.Fatalf("empty snapshot = %v", got)
	}
	for i := 0; i < 6; i++ {
		b.Limit(fmt.Sprint("a", i), orderbook.Sell, 50, 1_000_000_000, orderbook.GTC)
	}
	b.Limit("b", orderbook.Buy, 40, 1, orderbook.GTC)
	expect(t, b.Snapshot(), "BID 40 1 1", "ASK 50 6000000000 6", "--")
	expect(t, b.Limit("f", orderbook.Buy, 50, 6_000_000_001, orderbook.FOK), "REJECT f")
	if len(b.Snapshot()) != 3 {
		t.Error("Snapshot must not change the book")
	}
}

func TestDuplicateRestingIDRejected(t *testing.T) {
	b := orderbook.New()
	b.Limit("x", orderbook.Buy, 1, 1, orderbook.GTC)
	expect(t, b.Limit("x", orderbook.Sell, 1, 1, orderbook.GTC), "REJECT x")
}

func TestKeywordIDs(t *testing.T) {
	b := orderbook.New()
	expect(t, b.Limit("BUY", orderbook.Sell, 5, 1, orderbook.GTC), "REST BUY")
	expect(t, b.Cancel("BUY"), "CANCEL BUY 1")
}

func TestExecute(t *testing.T) {
	b := orderbook.New()
	cmds := []orderbook.Command{
		{Kind: orderbook.CmdLimit, ID: "a", Side: orderbook.Sell, Price: 10, Qty: 2},
		{Kind: orderbook.CmdMarket, ID: "m", Side: orderbook.Buy, Qty: 1},
		{Kind: orderbook.CmdReplace, ID: "a", Price: 10, Qty: 1},
		{Kind: orderbook.CmdBook},
		{Kind: orderbook.CmdCancel, ID: "a"},
	}
	var out []string
	for _, c := range cmds {
		out = append(out, strings.TrimSuffix(lines(b.Execute(c)), "\n"))
	}
	want := "REST a|TRADE m a 10 1\nFILLED m|REST a|ASK 10 1 1\n--|CANCEL a 1"
	if got := strings.Join(out, "|"); got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func ExampleBook() {
	b := orderbook.New()
	b.Limit("s1", orderbook.Sell, 101, 5, orderbook.GTC)
	for _, e := range b.Limit("b1", orderbook.Buy, 102, 8, orderbook.GTC) {
		fmt.Println(e)
	}
	for _, e := range b.Snapshot() {
		fmt.Println(e)
	}
	// Output:
	// TRADE b1 s1 101 5
	// FILLED s1
	// REST b1
	// BID 102 3 1
	// --
}
