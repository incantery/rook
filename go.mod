module github.com/incantery/rook

go 1.25.0

// The provider SDK is a separate module (sdk/provider/go.mod) so that a
// plugin author depends on the protocol alone. rook consumes it like
// anyone else would; the replace is what lets local edits to the SDK be
// picked up without a tag round-trip.
require github.com/incantery/rook/sdk/provider v0.1.0

// The drive loop — goal in, judged conversation out — is vera's, and
// this is the whole of what rook borrows to run it. vera's drive module
// imports the standard library and nothing else (that is what its own
// go.mod is FOR), so requiring it costs this module no transitive
// dependency and keeps the stdlib-only rule intact: rook supplies the
// mechanism (typing into a live pane), vera supplies the supervision.
require github.com/incantery/vera/drive v0.0.0-20260819221129-d21e4cba01cc

replace github.com/incantery/rook/sdk/provider => ./sdk/provider
