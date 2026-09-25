package acquire

import (
	"context"
	"testing"
	"time"
)

// A network change restarts what it stalled, once, after the new network has
// had a moment; a transfer still getting bytes is left alone.
func TestNetworkChangeRestartsStalledTransfers(t *testing.T) {
	backend := &fakeBackend{scheme: "torrent"}
	m, _, _ := testManager(t, backend)
	clock := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	m.now = func() time.Time { return clock }
	ctx := context.Background()
	if _, err := m.Start(ctx, torrentRequest()); err != nil {
		t.Fatalf("start: %v", err)
	}
	w := netWatch{addrs: "wifi"}

	clock = clock.Add(time.Minute)
	m.checkNetwork(ctx, &w, "wifi")
	if backend.starts != 1 {
		t.Fatalf("no change, but started %d times", backend.starts)
	}
	m.checkNetwork(ctx, &w, "wifi,vpn")
	if backend.starts != 1 {
		t.Fatal("restarted before the new network had a moment")
	}
	clock = clock.Add(stallAfter)
	m.checkNetwork(ctx, &w, "wifi,vpn")
	if backend.starts != 2 {
		t.Fatalf("stalled transfer started %d times, want 2", backend.starts)
	}
	clock = clock.Add(stallAfter)
	m.checkNetwork(ctx, &w, "wifi,vpn")
	if backend.starts != 2 {
		t.Fatalf("restarted twice for one change: %d starts", backend.starts)
	}
}

func TestNetworkChangeLeavesAMovingTransfer(t *testing.T) {
	task := &fakeTask{file: &fakeFile{path: "f.mkv", size: 100, head: 1}}
	backend := &fakeBackend{scheme: "torrent", task: task}
	m, _, _ := testManager(t, backend)
	clock := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	m.now = func() time.Time { return clock }
	ctx := context.Background()
	if _, err := m.Start(ctx, torrentRequest()); err != nil {
		t.Fatalf("start: %v", err)
	}
	w := netWatch{addrs: "wifi"}
	m.checkNetwork(ctx, &w, "wifi,vpn")
	for range 3 {
		clock = clock.Add(stallAfter / 2)
		task.mu.Lock()
		task.progress = Progress{Total: 100, Completed: 10, Peers: 3, Received: task.progress.Received + 10}
		task.mu.Unlock()
		m.checkNetwork(ctx, &w, "wifi,vpn")
	}
	if backend.starts != 1 {
		t.Fatalf("a transfer getting bytes was restarted: %d starts", backend.starts)
	}
}
