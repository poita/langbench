package protowire_test

import (
	"encoding/hex"
	"fmt"
	"testing"

	"protowire"
)

func Example() {
	sch, err := protowire.ParseSchema(`
		message Point { sint32 x = 1; sint32 y = 2; }
		message Path  { string name = 1; repeated Point points = 2; }`)
	if err != nil {
		panic(err)
	}
	c := protowire.NewCodec(sch)

	wireBytes, err := c.Encode("Path", `{name: "walk", points: [{x: 1, y: -1}, {x: 0, y: 2}]}`)
	if err != nil {
		panic(err)
	}
	fmt.Println(hex.EncodeToString(wireBytes))

	text, err := c.Decode("Path", wireBytes)
	if err != nil {
		panic(err)
	}
	fmt.Println(text)
	// Output:
	// 0a0477616c6b12040802100112021004
	// {name: "walk", points: [{x: 1, y: -1}, {y: 2}]}
}

func ExampleProcess() {
	out, _ := protowire.Process([]byte("message M { int32 a = 1; }\n--\nencode M {a: 300}\ndecode M 08\n"))
	fmt.Print(string(out))
	// Output:
	// 08ac02
	// error
}

func TestDecodeErrorIsReported(t *testing.T) {
	sch, _ := protowire.ParseSchema("message M { int32 a = 1; }")
	if _, err := protowire.NewCodec(sch).Decode("M", []byte{0x08}); err == nil {
		t.Error("expected error")
	}
}
