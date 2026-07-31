// The provider SDK is its own module, and its go.mod is deliberately
// this short: a plugin author's dependency on rook is the protocol and
// nothing else. rook's own go.mod carries a sqlite driver, a websocket
// library and a TOML parser — none of which anyone writing a provider
// should have to resolve, audit, or explain to their security team.
//
// It versions on its own too. The protocol will move faster than the
// app, and slower once it stops moving; tying the two to one number
// would make every rook release look like a protocol change.
module github.com/incantery/rook/sdk/provider

go 1.25.0
