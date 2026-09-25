// Package flight runs one fetch per key at a time, shared by everyone who asks
// while it is out. Unlike x/sync/singleflight, the fetch runs on the group's
// own context rather than the first caller's: a caller that leaves (a page
// closed before the provider answered) stops waiting, but the answer is still
// fetched and kept, and Close cancels and waits for what is out so nothing
// writes to a store after it is closed.
package flight

import (
	"context"
	"errors"
	"sync"
)

// ErrClosed is the answer to a fetch asked for after Close.
var ErrClosed = errors.New("flight: group closed")

type Group[T any] struct {
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup

	mu     sync.Mutex
	closed bool
	calls  map[string]*Call[T]
}

func New[T any]() *Group[T] {
	ctx, cancel := context.WithCancel(context.Background())
	return &Group[T]{ctx: ctx, cancel: cancel, calls: make(map[string]*Call[T])}
}

// Call is one fetch in flight.
type Call[T any] struct {
	done chan struct{}
	val  T
	err  error
}

// Go returns the fetch in flight under key, starting fetch if there is none.
func (g *Group[T]) Go(key string, fetch func(context.Context) (T, error)) *Call[T] {
	g.mu.Lock()
	defer g.mu.Unlock()
	if c, ok := g.calls[key]; ok {
		return c
	}
	c := &Call[T]{done: make(chan struct{})}
	if g.closed {
		c.err = ErrClosed
		close(c.done)
		return c
	}
	g.calls[key] = c
	g.wg.Add(1)
	go func() {
		defer g.wg.Done()
		c.val, c.err = fetch(g.ctx)
		g.mu.Lock()
		delete(g.calls, key)
		g.mu.Unlock()
		close(c.done)
	}()
	return c
}

// Do is Go and Wait.
func (g *Group[T]) Do(ctx context.Context, key string, fetch func(context.Context) (T, error)) (T, error) {
	return g.Go(key, fetch).Wait(ctx)
}

// Wait returns the fetch's answer, or ctx's error if the caller stops waiting
// first; the fetch itself carries on.
func (c *Call[T]) Wait(ctx context.Context) (T, error) {
	select {
	case <-c.done:
		return c.val, c.err
	case <-ctx.Done():
		var zero T
		return zero, ctx.Err()
	}
}

// Close cancels the fetches in flight and waits for them. Fetches asked for
// after it fail with ErrClosed. It is safe to call more than once.
func (g *Group[T]) Close() {
	g.mu.Lock()
	g.closed = true
	g.mu.Unlock()
	g.cancel()
	g.wg.Wait()
}

// Wait waits for the fetches in flight to finish without cancelling them.
// Tests use it to see what a background fetch left behind.
func (g *Group[T]) Wait() { g.wg.Wait() }
