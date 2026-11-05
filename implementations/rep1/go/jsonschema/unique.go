package jsonschema

import "example.com/jsonschema/jsonvalue"

// allUnique reports whether no two elements of arr are JSON-equal. Small
// arrays are compared pairwise; larger ones bucket elements by a hash that is
// consistent with JSON equality and compare only within buckets.
func allUnique(arr []jsonvalue.Value) bool {
	if len(arr) <= 12 {
		for i := 1; i < len(arr); i++ {
			for j := 0; j < i; j++ {
				if jsonvalue.Equal(arr[i], arr[j]) {
					return false
				}
			}
		}
		return true
	}
	buckets := make(map[uint64][]int, len(arr))
	for i := range arr {
		h := jsonvalue.Hash(arr[i])
		for _, j := range buckets[h] {
			if jsonvalue.Equal(arr[i], arr[j]) {
				return false
			}
		}
		buckets[h] = append(buckets[h], i)
	}
	return true
}
