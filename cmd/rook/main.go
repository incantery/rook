// Command rook boots an opinionated tmux session: tmux, sesh and zoxide
// wired the way this repo thinks they should be, so that opening a
// terminal and running `rook` is the whole setup. The multiplexer, the
// session manager and the jump list are dependencies, not rewrites.
//
// Nothing is implemented yet beyond proving the binary builds and runs.
package main

import (
	"fmt"
)

func main() {
	fmt.Println("rook: hello")
}
