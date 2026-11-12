package protocol

import (
	"errors"
	"fmt"

	"github.com/peteralexander/orderbook"
)

// ErrSyntax is wrapped by every error returned from [ParseCommand].
var ErrSyntax = errors.New("protocol: malformed command")

func syntaxErr(line []byte, why string) error {
	return fmt.Errorf("%w: %s: %q", ErrSyntax, why, line)
}

// fields splits line on single spaces into dst without allocating.
func fields(dst [][]byte, line []byte) [][]byte {
	start := 0
	for i := 0; i <= len(line); i++ {
		if i == len(line) || line[i] == ' ' {
			dst = append(dst, line[start:i])
			start = i + 1
		}
	}
	return dst
}

func parseUint(b []byte) (uint64, bool) {
	if len(b) == 0 || len(b) > 19 {
		return 0, false
	}
	var v uint64
	for _, c := range b {
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + uint64(c-'0')
	}
	return v, true
}

func parseSide(b []byte) (orderbook.Side, bool) {
	switch string(b) {
	case "BUY":
		return orderbook.Buy, true
	case "SELL":
		return orderbook.Sell, true
	}
	return 0, false
}

// ParseCommand parses one command line (without its line terminator).
func ParseCommand(line []byte) (orderbook.Command, error) {
	var buf [8][]byte
	f := fields(buf[:0], line)
	var c orderbook.Command
	var ok bool
	bad := func(why string) (orderbook.Command, error) { return orderbook.Command{}, syntaxErr(line, why) }

	switch string(f[0]) {
	case "LIMIT":
		if len(f) != 5 && len(f) != 6 {
			return bad("LIMIT takes 4 or 5 arguments")
		}
		c.Kind = orderbook.CmdLimit
		c.ID = string(f[1])
		if c.Side, ok = parseSide(f[2]); !ok {
			return bad("bad side")
		}
		if c.Price, ok = parseUint(f[3]); !ok {
			return bad("bad price")
		}
		if c.Qty, ok = parseUint(f[4]); !ok {
			return bad("bad quantity")
		}
		if len(f) == 6 {
			switch string(f[5]) {
			case "IOC":
				c.TIF = orderbook.IOC
			case "FOK":
				c.TIF = orderbook.FOK
			default:
				return bad("bad time-in-force flag")
			}
		}
	case "MARKET":
		if len(f) != 4 {
			return bad("MARKET takes 3 arguments")
		}
		c.Kind = orderbook.CmdMarket
		c.ID = string(f[1])
		if c.Side, ok = parseSide(f[2]); !ok {
			return bad("bad side")
		}
		if c.Qty, ok = parseUint(f[3]); !ok {
			return bad("bad quantity")
		}
	case "CANCEL":
		if len(f) != 2 {
			return bad("CANCEL takes 1 argument")
		}
		c.Kind = orderbook.CmdCancel
		c.ID = string(f[1])
	case "REPLACE":
		if len(f) != 4 {
			return bad("REPLACE takes 3 arguments")
		}
		c.Kind = orderbook.CmdReplace
		c.ID = string(f[1])
		if c.Price, ok = parseUint(f[2]); !ok {
			return bad("bad price")
		}
		if c.Qty, ok = parseUint(f[3]); !ok {
			return bad("bad quantity")
		}
	case "BOOK":
		if len(f) != 1 {
			return bad("BOOK takes no arguments")
		}
		c.Kind = orderbook.CmdBook
	default:
		return bad("unknown command")
	}
	return c, nil
}
