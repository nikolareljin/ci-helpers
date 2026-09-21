package api

import "testing"

func TestName(t *testing.T) {
	if got := Name(); got != "api" {
		t.Fatalf("got %q, want %q", got, "api")
	}
}
