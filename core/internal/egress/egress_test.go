package egress

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// tarpit forwards TCP to target until blackhole is called; from then on the
// connections it already holds stay open and carry nothing, like a NAT or a
// VPN that dropped them.
type tarpit struct {
	ln     net.Listener
	target string
	mu     sync.Mutex
	dead   []*atomic.Bool
	dials  atomic.Int32
}

func newTarpit(t *testing.T, target string) *tarpit {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p := &tarpit{ln: ln, target: target}
	t.Cleanup(func() { ln.Close() })
	go p.serve()
	return p
}

func (p *tarpit) serve() {
	for {
		in, err := p.ln.Accept()
		if err != nil {
			return
		}
		p.dials.Add(1)
		out, err := net.Dial("tcp", p.target)
		if err != nil {
			in.Close()
			continue
		}
		dead := new(atomic.Bool)
		p.mu.Lock()
		p.dead = append(p.dead, dead)
		p.mu.Unlock()
		go io.Copy(sink{out, dead}, in)
		go io.Copy(sink{in, dead}, out)
	}
}

func (p *tarpit) blackhole() {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, d := range p.dead {
		d.Store(true)
	}
}

type sink struct {
	w    io.Writer
	dead *atomic.Bool
}

func (s sink) Write(b []byte) (int, error) {
	if s.dead.Load() {
		return len(b), nil
	}
	return s.w.Write(b)
}

func TestRetryOutlivesASilentConnection(t *testing.T) {
	// The second request hangs until its connection is blackholed, so the
	// retry, not an earlier ping, is what has to rescue it.
	var calls atomic.Int32
	caught, release := make(chan struct{}), make(chan struct{})
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) == 2 {
			close(caught)
			<-release
			return
		}
		io.WriteString(w, "ok")
	}))
	srv.EnableHTTP2 = true
	srv.StartTLS()
	defer srv.Close()
	defer close(release)
	pit := newTarpit(t, srv.Listener.Addr().String())

	h2 := h2Transport()
	h2.TLSClientConfig = srv.Client().Transport.(*http.Transport).TLSClientConfig
	// Short enough for a test; the production timings are the constants above.
	h2.HTTP2 = &http.HTTP2Config{SendPingTimeout: 300 * time.Millisecond, PingTimeout: 300 * time.Millisecond}
	client := &http.Client{Transport: retry{h2}, Timeout: 10 * time.Second}
	url := "https://" + pit.ln.Addr().String() + "/"

	get := func() {
		t.Helper()
		resp, err := client.Get(url)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if resp.ProtoMajor != 2 {
			t.Fatalf("proto %s, want HTTP/2", resp.Proto)
		}
		if b, _ := io.ReadAll(resp.Body); string(b) != "ok" {
			t.Fatalf("body %q", b)
		}
	}
	get()
	go func() {
		<-caught
		pit.blackhole()
	}()
	get()
	if n := pit.dials.Load(); n != 2 {
		t.Fatalf("%d connections, want 2", n)
	}
}
