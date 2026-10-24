// Package gonew uses new(expr), which Go 1.26 added, so a tool built with an
// older Go cannot load it.
package gonew

// Answer returns a pointer to 42.
func Answer() *int { return new(42) }
