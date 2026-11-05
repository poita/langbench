package rrule_test

import (
	"fmt"

	"github.com/example/rrule"
)

func ExampleRule_Expand() {
	r, err := rrule.ParseRule("FREQ=MONTHLY;BYDAY=-1FR;COUNT=3")
	if err != nil {
		panic(err)
	}
	start, _ := rrule.ParseDateTime("19970902T090000")
	times, _ := r.Expand(start, 100)
	for _, t := range times {
		fmt.Println(t)
	}
	// Output:
	// 19970926T090000
	// 19971031T090000
	// 19971128T090000
}

func ExampleExpander_AppendText() {
	e := rrule.NewExpander()
	r, _ := rrule.ParseRule("FREQ=DAILY;INTERVAL=2")
	start, _ := rrule.ParseDateTime("20240228T120000")
	out, _ := e.AppendText(nil, r, start, 3)
	fmt.Println(string(out))
	// Output: 20240228T120000 20240301T120000 20240303T120000
}
