package racy

import (
	"sync"
	"testing"
)

// Two goroutines write n without a lock. The test passes without -race and
// fails with it, which is what the self-test checks.
func TestRacyCounter(t *testing.T) {
	n := 0
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 1000; j++ {
				n++
			}
		}()
	}
	wg.Wait()
	_ = n
}
