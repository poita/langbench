package bigint_test

import (
	"fmt"

	"github.com/peteralexander/bigint"
)

func Example() {
	a := bigint.MustParse("-123456789012345678901234567890")
	b := bigint.MustParse("987654321098765432109876543210")
	fmt.Println(a.Mul(b))

	q, r, _ := bigint.New(-7).QuoRem(bigint.New(2))
	fmt.Println(q, r)

	p, _ := bigint.New(2).Exp(bigint.New(100))
	fmt.Println(p)
	// Output:
	// -121932631137021795226185032733622923332237463801111263526900
	// -3 -1
	// 1267650600228229401496703205376
}
