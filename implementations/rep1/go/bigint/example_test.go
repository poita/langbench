package bigint_test

import (
	"fmt"

	"github.com/example/bigint"
)

func Example() {
	a := bigint.MustParse("123456789012345678901234567890")
	b := bigint.FromInt64(-987654321)

	fmt.Println(a.Add(b))
	fmt.Println(a.Mul(b))

	q, r, _ := a.DivMod(b)
	fmt.Println(q, r)

	p, _ := bigint.FromInt64(2).Exp(bigint.FromInt64(100))
	fmt.Println(p)
	// Output:
	// 123456789012345678900246913569
	// -121932631124828532112482853211126352690
	// -124999998873437499901 574845669
	// 1267650600228229401496703205376
}
