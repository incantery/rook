module github.com/incantery/rook

go 1.25.0

// The provider SDK is a separate module (sdk/provider/go.mod) so that a
// plugin author depends on the protocol alone. rook consumes it like
// anyone else would; the replace is what lets local edits to the SDK be
// picked up without a tag round-trip.
require github.com/incantery/rook/sdk/provider v0.1.0

replace github.com/incantery/rook/sdk/provider => ./sdk/provider
