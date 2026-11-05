package bigint_test

import (
	"fmt"

	"github.com/example/bigint"
)

func Example() {
	a, _ := bigint.Parse("-123456789012345678901234567890")
	b, _ := bigint.Parse("987654321098765432109876543210")
	fmt.Println(a.Mul(b))

	q, r, _ := bigint.NewInt(-7).QuoRem(bigint.NewInt(2))
	fmt.Println(q, r)

	p, _ := bigint.NewInt(2).Exp(bigint.NewInt(100))
	fmt.Println(p)

	_, err := bigint.NewInt(1).Quo(bigint.NewInt(0))
	fmt.Println(err)
	// Output:
	// -121932631137021795226185032733622923332237463801111263526900
	// -3 -1
	// 1267650600228229401496703205376
	// bigint: division by zero
}
