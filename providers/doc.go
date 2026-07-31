// Package providers is not code. It is the directory every provider
// lives in — one per external system, each its own main package — and
// the home of the test that keeps them honest.
//
// A provider must be writable by someone who has never seen rook's
// source: the SDK (its own module, github.com/incantery/rook/sdk/provider,
// which depends on nothing) plus the standard library. The providers rook
// ships are the only standing evidence that this is true, so they live
// under the same rule, enforced by boundary_test.go rather than described
// in a comment.
package providers
