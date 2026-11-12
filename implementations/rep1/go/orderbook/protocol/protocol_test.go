package protocol_test

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/peteralexander/orderbook"
	"github.com/peteralexander/orderbook/protocol"
)

func TestParseCommand(t *testing.T) {
	tests := []struct {
		line string
		want orderbook.Command
	}{
		{"LIMIT a BUY 100 5", orderbook.Command{Kind: orderbook.CmdLimit, ID: "a", Side: orderbook.Buy, Price: 100, Qty: 5}},
		{"LIMIT a SELL 1 1000000000 IOC", orderbook.Command{Kind: orderbook.CmdLimit, ID: "a", Side: orderbook.Sell, Price: 1, Qty: 1000000000, TIF: orderbook.IOC}},
		{"LIMIT BUY BUY 7 2 FOK", orderbook.Command{Kind: orderbook.CmdLimit, ID: "BUY", Side: orderbook.Buy, Price: 7, Qty: 2, TIF: orderbook.FOK}},
		{"MARKET m SELL 9", orderbook.Command{Kind: orderbook.CmdMarket, ID: "m", Side: orderbook.Sell, Qty: 9}},
		{"CANCEL BOOK", orderbook.Command{Kind: orderbook.CmdCancel, ID: "BOOK"}},
		{"REPLACE x 12 34", orderbook.Command{Kind: orderbook.CmdReplace, ID: "x", Price: 12, Qty: 34}},
		{"BOOK", orderbook.Command{Kind: orderbook.CmdBook}},
	}
	for _, tc := range tests {
		got, err := protocol.ParseCommand([]byte(tc.line))
		if err != nil || got != tc.want {
			t.Errorf("ParseCommand(%q) = %+v, %v; want %+v", tc.line, got, err, tc.want)
		}
	}
}

func TestParseCommandErrors(t *testing.T) {
	for _, line := range []string{
		"", "NOPE", "LIMIT a BUY 1", "LIMIT a UP 1 1", "LIMIT a BUY x 1", "LIMIT a BUY 1 1 GTC",
		"MARKET a BUY", "CANCEL", "CANCEL a b", "REPLACE a 1", "BOOK now", "LIMIT a BUY 1 -1",
	} {
		if _, err := protocol.ParseCommand([]byte(line)); !errors.Is(err, protocol.ErrSyntax) {
			t.Errorf("ParseCommand(%q): err = %v, want ErrSyntax", line, err)
		}
	}
}

func TestAppendEvent(t *testing.T) {
	tests := []struct {
		e    orderbook.Event
		want string
	}{
		{orderbook.Event{Kind: orderbook.Trade, ID: "t", MakerID: "m", Price: 5, Qty: 6}, "TRADE t m 5 6\n"},
		{orderbook.Event{Kind: orderbook.Rest, ID: "a"}, "REST a\n"},
		{orderbook.Event{Kind: orderbook.Cancel, ID: "a", Qty: 4294967296}, "CANCEL a 4294967296\n"},
		{orderbook.Event{Kind: orderbook.Reject, ID: "a"}, "REJECT a\n"},
		{orderbook.Event{Kind: orderbook.Filled, ID: "a"}, "FILLED a\n"},
		{orderbook.Event{Kind: orderbook.Bid, Price: 1, Qty: 2, Orders: 3}, "BID 1 2 3\n"},
		{orderbook.Event{Kind: orderbook.Ask, Price: 1, Qty: 2, Orders: 3}, "ASK 1 2 3\n"},
		{orderbook.Event{Kind: orderbook.EndBook}, "--\n"},
	}
	for _, tc := range tests {
		if got := string(protocol.AppendEvent([]byte("x"), tc.e)); got != "x"+tc.want {
			t.Errorf("AppendEvent(%+v) = %q, want %q", tc.e, got, "x"+tc.want)
		}
		if s := tc.e.String() + "\n"; s != tc.want {
			t.Errorf("String() = %q, want %q", s, tc.want)
		}
	}
}

func run(t *testing.T, in string) string {
	t.Helper()
	var out bytes.Buffer
	if err := protocol.Run(strings.NewReader(in), &out); err != nil {
		t.Fatalf("Run(%q): %v", in, err)
	}
	return out.String()
}

func TestRunEdgeCases(t *testing.T) {
	if got := run(t, "0\n"); got != "" {
		t.Errorf("N=0 output = %q, want empty", got)
	}
	if got := run(t, ""); got != "" {
		t.Errorf("empty input output = %q, want empty", got)
	}
	if got := run(t, "1\nBOOK"); got != "--\n" { // no trailing newline
		t.Errorf("got %q", got)
	}
	if got := run(t, "2\nLIMIT a BUY 1 1\nCANCEL a\n"); got != "REST a\nCANCEL a 1\n" {
		t.Errorf("got %q", got)
	}
}

func TestRunErrors(t *testing.T) {
	var out bytes.Buffer
	if err := protocol.Run(strings.NewReader("x\n"), &out); !errors.Is(err, protocol.ErrSyntax) {
		t.Errorf("bad count: err = %v", err)
	}
	if err := protocol.Run(strings.NewReader("1\nFOO\n"), &out); !errors.Is(err, protocol.ErrSyntax) {
		t.Errorf("bad command: err = %v", err)
	}
}

func TestRunLargeOutputFlushes(t *testing.T) {
	var in strings.Builder
	const n = 20000
	in.WriteString("20000\n")
	for i := 0; i < n; i++ {
		in.WriteString("CANCEL some-unknown-order-id\n")
	}
	got := run(t, in.String())
	if want := strings.Repeat("REJECT some-unknown-order-id\n", n); got != want {
		t.Error("large output mismatch")
	}
}

// TestGolden runs every testdata/*.in through Run and compares with .out.
func TestGolden(t *testing.T) {
	files, err := filepath.Glob("../testdata/*.in")
	if err != nil || len(files) == 0 {
		t.Fatalf("no golden files: %v", err)
	}
	for _, f := range files {
		in, _ := os.ReadFile(f)
		want, err := os.ReadFile(strings.TrimSuffix(f, ".in") + ".out")
		if err != nil {
			t.Fatal(err)
		}
		if got := run(t, string(in)); got != string(want) {
			t.Errorf("%s: output differs\n got:\n%s\nwant:\n%s", filepath.Base(f), got, want)
		}
	}
}
