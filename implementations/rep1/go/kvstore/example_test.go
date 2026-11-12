package tessera_test

import (
	"fmt"

	"example.com/tessera"
	"example.com/tessera/value"
)

func Example() {
	db := tessera.Open(nil, nil) // a fresh, empty database

	doc := value.ObjectValue(
		value.Field{Name: "name", Val: value.StringValue("ada")},
		value.Field{Name: "age", Val: value.IntValue(36)},
	)
	if _, err := db.Put([]byte("u1"), doc); err != nil {
		panic(err)
	}
	if _, err := db.CreateIndex("age"); err != nil {
		panic(err)
	}

	pred := tessera.Cmp([]string{"age"}, tessera.OpGe, value.IntValue(30))
	entries, plan := db.Find(pred, -1)
	fmt.Println("plan:", plan)
	for _, e := range entries {
		fmt.Printf("%s = %s\n", e.Key, value.Render(e.Doc))
	}

	// The command language drives the same engine.
	fmt.Println(db.Exec(`update "u1" address.city "Perth"`).Status)

	// Everything is in the write-ahead log until a checkpoint.
	n, _ := db.Checkpoint()
	fmt.Println("checkpointed pages:", n, "log bytes:", len(db.LogFile()))
	// Output:
	// plan: index age
	// u1 = {"age":36,"name":"ada"}
	// ok update updated
	// checkpointed pages: 3 log bytes: 32
}
