package flight

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
)

func TestCallersJoinOneFetch(t *testing.T) {
	g := New[int]()
	defer g.Close()
	release := make(chan struct{})
	var fetches atomic.Int32
	fetch := func(context.Context) (int, error) {
		fetches.Add(1)
		<-release
		return 42, nil
	}
	first := g.Go("k", fetch)
	second := g.Go("k", fetch)
	if first != second {
		t.Fatal("a second caller started its own fetch")
	}
	close(release)
	for _, c := range []*Call[int]{first, second} {
		if v, err := c.Wait(context.Background()); v != 42 || err != nil {
			t.Errorf("got %d, %v", v, err)
		}
	}
	if fetches.Load() != 1 {
		t.Errorf("fetched %d times, want 1", fetches.Load())
	}
	// Done: the next caller fetches afresh.
	if _, err := g.Do(context.Background(), "k", func(context.Context) (int, error) { fetches.Add(1); return 0, nil }); err != nil || fetches.Load() != 2 {
		t.Errorf("finished fetch was reused: %v, %d fetches", err, fetches.Load())
	}
}

func TestLeavingCallerDoesNotCancelTheFetch(t *testing.T) {
	g := New[int]()
	release := make(chan struct{})
	var fetchErr error
	c := g.Go("k", func(ctx context.Context) (int, error) {
		<-release
		fetchErr = ctx.Err()
		return 1, nil
	})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := c.Wait(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v, want context.Canceled", err)
	}
	close(release)
	g.Wait()
	if fetchErr != nil {
		t.Errorf("the fetch saw its context end with %v", fetchErr)
	}
	g.Close()
}

func TestCloseCancelsAndWaits(t *testing.T) {
	g := New[int]()
	var finished atomic.Bool
	g.Go("k", func(ctx context.Context) (int, error) {
		<-ctx.Done()
		finished.Store(true)
		return 0, ctx.Err()
	})
	g.Close()
	if !finished.Load() {
		t.Error("Close returned before the fetch ended")
	}
	if _, err := g.Do(context.Background(), "k", func(context.Context) (int, error) { return 1, nil }); !errors.Is(err, ErrClosed) {
		t.Errorf("fetch after Close: %v, want ErrClosed", err)
	}
	g.Close()
}
