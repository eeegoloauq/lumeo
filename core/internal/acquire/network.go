package acquire

import (
	"context"
	"net"
	"slices"
	"strings"
	"time"
)

const (
	// networkPoll is how often the machine's addresses are compared. A VPN
	// going up or down, or another Wi-Fi, changes them.
	networkPoll = 5 * time.Second
	// recoverWithin is how long after a change a stalled transfer is still
	// put down to it.
	recoverWithin = 2 * time.Minute
)

// netWatch is what WatchNetwork remembers between two looks.
type netWatch struct {
	addrs   string
	changed time.Time
	// The transfers running when the addresses changed, each restarted at
	// most once for it.
	pending map[string]bool
}

// WatchNetwork restarts the transfers a network change left stalled. Their
// peer connections went with the old route, but nothing tells the torrent
// client so: it keeps waiting on them and does not look for new ones until the
// core restarts. A transfer still getting bytes is left alone.
func (m *Manager) WatchNetwork(ctx context.Context) {
	w := netWatch{addrs: localAddrs()}
	tick := time.NewTicker(networkPoll)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			if addrs := localAddrs(); addrs != "" {
				m.checkNetwork(ctx, &w, addrs)
			}
		}
	}
}

func (m *Manager) checkNetwork(ctx context.Context, w *netWatch, addrs string) {
	now := m.now()
	if addrs != w.addrs {
		w.addrs, w.changed = addrs, now
		w.pending = map[string]bool{}
		m.mu.Lock()
		for id := range m.tasks {
			w.pending[id] = true
		}
		m.mu.Unlock()
	}
	// Not at once: the new network needs a moment (DNS, routes) before a
	// fresh torrent can announce on it, and a dead connection a moment to
	// show as a stall.
	since := now.Sub(w.changed)
	if since < stallAfter {
		return
	}
	if since > recoverWithin {
		w.pending = nil
		return
	}
	for id := range w.pending {
		m.recover(ctx, id, now, w)
	}
}

func (m *Manager) recover(ctx context.Context, id string, now time.Time, w *netWatch) {
	m.startMu.Lock()
	defer m.startMu.Unlock()
	m.mu.Lock()
	row, ok := m.rows[id]
	m.mu.Unlock()
	if !ok || !m.running(id) || row.Locator.Scheme == "file" {
		delete(w.pending, id)
		return
	}
	row = m.snapshot(ctx, row)
	if row.State == StateDone {
		delete(w.pending, id)
		return
	}
	if !stalled(row, now) {
		return
	}
	delete(w.pending, id)
	m.log.Info("restarting a download the network change stalled", "download", id)
	m.stopTask(id)
	if err := m.restart(ctx, row); err != nil {
		m.log.Warn("restarting download failed", "download", id, "err", err)
	}
}

// localAddrs is the machine's addresses as one comparable string, or "" when
// they cannot be read.
func localAddrs() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	out := make([]string, 0, len(addrs))
	for _, a := range addrs {
		out = append(out, a.String())
	}
	slices.Sort(out)
	return strings.Join(out, ",")
}
