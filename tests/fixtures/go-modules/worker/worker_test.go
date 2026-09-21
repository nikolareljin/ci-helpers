package worker

import "testing"

func TestName(t *testing.T) {
	if got := Name(); got != "worker" {
		t.Fatalf("got %q, want %q", got, "worker")
	}
}
