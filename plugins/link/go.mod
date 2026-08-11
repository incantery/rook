module github.com/incantery/rook/plugins/link

go 1.25.4

// The link plugin lives in rook's tree but is its own module, so it can
// carry dependencies the stdlib-only root refuses. The replace is what
// lets it share plugins/internal/* with the cloud bridge.
replace github.com/incantery/rook => ../..

require (
	github.com/incantery/rook v0.0.0-00010101000000-000000000000
	github.com/incantery/rook-host v0.4.0
	github.com/skip2/go-qrcode v0.0.0-20200617195104-da1b6568686e
	golang.org/x/term v0.45.0
)

require (
	connectrpc.com/connect v1.20.0 // indirect
	github.com/brutella/dnssd v1.2.14 // indirect
	github.com/miekg/dns v1.1.61 // indirect
	github.com/vishvananda/netlink v1.2.1-beta.2 // indirect
	github.com/vishvananda/netns v0.0.0-20200728191858-db3c7e526aae // indirect
	golang.org/x/mod v0.18.0 // indirect
	golang.org/x/net v0.26.0 // indirect
	golang.org/x/sync v0.7.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/tools v0.22.0 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
)
