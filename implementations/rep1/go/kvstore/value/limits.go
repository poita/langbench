package value

// Limits fixed by the Tessera specification.
const (
	MaxKey          = 128        // maximum primary key length in bytes
	MaxDoc          = 65536      // maximum serialised document length in bytes
	MaxDepth        = 32         // maximum value nesting depth
	MaxPath         = 30         // maximum field-path text length in bytes
	MaxPathSegments = 8          // maximum number of segments in a field path
	MaxLimit        = 2147483647 // largest accepted limit argument
)
