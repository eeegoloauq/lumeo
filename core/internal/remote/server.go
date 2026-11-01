package remote

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/egress"
)

// ErrUnreachable is a request that got no answer from the server.
var ErrUnreachable = errors.New("server unreachable")

// ModeHeader carries a core's mode on every answer it gives, so a core
// forwarding to it learns at once when it stops being a media server.
const ModeHeader = "Lumeo-Mode"

// ModeMedia is a server that leaves its devices' personal data on them. It
// is the only kind a core forwards to: a full server keeps that data itself,
// and the two would disagree about where it lives.
const ModeMedia = "media"

// ErrNotMedia is an answer from a server that is not, or is no longer, a
// media server. Nothing is forwarded to it then: carrying on would leave the
// viewer's data split between the two cores.
var ErrNotMedia = errors.New("the server is not a media server")

// checkMode refuses an answer from a server that does not say it is a media
// server. An answer without the header and with a gateway error is the proxy
// in front of the server talking, not the server, and is left to the caller.
func checkMode(resp *http.Response) error {
	mode := resp.Header.Get(ModeHeader)
	switch {
	case mode == ModeMedia:
		return nil
	case mode == "" && resp.StatusCode >= 500:
		return nil
	case mode == "":
		return fmt.Errorf("%w: it did not say what it is; update it", ErrNotMedia)
	}
	return fmt.Errorf("%w: its owner set it to %s, so the viewer's data would live there; set LUMEO_MODE=media on it, or pair the client with it directly", ErrNotMedia, mode)
}

// StatusError is the server answering with an error. Body is its answer as
// it came, for a caller that passes it on.
type StatusError struct {
	Code int
	Body []byte
}

func (e *StatusError) Error() string {
	var answer struct {
		Error string `json:"error"`
	}
	if json.Unmarshal(e.Body, &answer) == nil && answer.Error != "" {
		return fmt.Sprintf("server answered %d: %s", e.Code, answer.Error)
	}
	return fmt.Sprintf("server answered %d", e.Code)
}

// Title is how the server knows one of its items: our ids are minted per
// core, so the two meet by IMDb id.
type Title struct {
	IMDb string
	Kind catalog.Kind
}

// Server is the server this core forwards to.
type Server struct {
	link   Link
	client *http.Client
	// artwork fetches the server's images: no credential, and an image's
	// time limit rather than an answer's.
	artwork *http.Client
	proxy   *httputil.ReverseProxy
	log    *slog.Logger

	// The server's ids for the titles seen in its answers, both ways. Kept in
	// memory only: they are learned again from the next answer, and a link
	// to another server starts with none of the last one's.
	mu       sync.Mutex
	byServer map[string]Title
	byIMDb   map[string]string
	// unknown is the server's ids it said it has no item for, such as a
	// file it opened that nothing matched: asked once, not on every list.
	unknown map[string]error

	rowsMu sync.Mutex
	rows   []catalog.Row
}

func New(link Link, log *slog.Logger) *Server {
	link.URL = strings.TrimRight(link.URL, "/")
	// A link that loads has a certificate that parses (Validate).
	transport, err := newTransport(link)
	if err != nil {
		log.Error("the link's certificate", "err", err)
		transport, _ = newTransport(Link{})
	}
	s := &Server{
		link:     link,
		client:   &http.Client{Transport: transport, CheckRedirect: refuseRedirect},
		artwork:  &http.Client{Transport: transport, CheckRedirect: refuseRedirect, Timeout: 20 * time.Second},
		log:      log,
		byServer: make(map[string]Title),
		byIMDb:   make(map[string]string),
		unknown:  make(map[string]error),
	}
	target, _ := url.Parse(link.URL)
	s.proxy = &httputil.ReverseProxy{
		Transport: transport,
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			// The client's token is this core's, not the server's.
			pr.Out.Header.Set("Authorization", "Bearer "+link.Token)
			pr.Out.Header.Del("Cookie")
		},
		// A stream is passed on as it arrives: nothing of it is held here
		// beyond the copy's own buffer.
		FlushInterval: -1,
		ModifyResponse: func(resp *http.Response) error {
			if err := checkMode(resp); err != nil {
				return err
			}
			if resp.StatusCode == http.StatusUnauthorized {
				return errRefused
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			if r.Context().Err() != nil {
				return // the player gave up; there is nobody to answer
			}
			if errors.Is(err, errRefused) {
				writeError(w, http.StatusBadGateway, RefusedMessage)
				return
			}
			if errors.Is(err, ErrNotMedia) {
				s.log.Error("the server is not a media server", "err", err)
				writeError(w, http.StatusBadGateway, err.Error())
				return
			}
			s.log.Warn("forwarding to the server failed", "path", r.URL.Path, "err", err)
			writeError(w, http.StatusBadGateway, ErrUnreachable.Error())
		},
	}
	return s
}

// RefusedMessage is what a client is told when the server no longer takes
// this core's credential. Never passed on as a 401: to the client that means
// its own token for this core is wrong.
const RefusedMessage = "the server refused this device"

var errRefused = errors.New(RefusedMessage)

func newTransport(link Link) (*http.Transport, error) {
	t := http.DefaultTransport.(*http.Transport).Clone()
	// Long enough for the server's own waits behind an answer: a magnet link
	// learning its file, a subtitle lookup, every source addon.
	t.ResponseHeaderTimeout = time.Minute
	// A pinned certificate is the one root, checked under the link's name
	// as any other: pairing made sure it carries that name.
	pool, err := link.pinned()
	if err != nil {
		return nil, err
	}
	if pool != nil {
		t.TLSClientConfig = &tls.Config{RootCAs: pool}
	}
	return t, nil
}

// The credential must not follow a redirect to another host.
func refuseRedirect(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

// URL is the server's origin.
func (s *Server) URL() string { return s.link.URL }

// Certificate is the PEM of the server's pinned certificate, empty when the
// link trusts the system's authorities.
func (s *Server) Certificate() string { return s.link.Certificate }

// Artwork says whether raw is one of the server's images, as its artwork
// route names them: a key and at most a fallback key. Only these are fetched
// over the link, so nothing an addon names reaches the user's network that way.
func (s *Server) Artwork(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme+"://"+u.Host != s.link.URL || u.User != nil || u.Fragment != "" || u.ForceQuery {
		return false
	}
	key, ok := strings.CutPrefix(u.EscapedPath(), "/api/v1/artwork/")
	if !ok || !artworkKey(key) {
		return false
	}
	if u.RawQuery == "" {
		return true
	}
	query, err := url.ParseQuery(u.RawQuery)
	return err == nil && len(query) == 1 && len(query["or"]) == 1 && artworkKey(query.Get("or"))
}

func artworkKey(key string) bool {
	return len(key) == 32 && strings.Trim(key, "0123456789abcdef") == ""
}

// FetchArtwork gets one of the server's images on the link's own address and
// trust: the server may be on the user's network or pin its certificate,
// which the public-address check on addon artwork would refuse. The route
// needs no credential, so none is sent.
func (s *Server) FetchArtwork(ctx context.Context, raw string) (*http.Response, error) {
	if !s.Artwork(raw) {
		return nil, errors.New("remote: not the server's artwork")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, raw, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", egress.UserAgent)
	return s.artwork.Do(req)
}

// Do sends one request with a JSON body, when body is not nil, and decodes
// the answer into out, when out is not nil.
func (s *Server) Do(ctx context.Context, method, path string, query url.Values, body, out any) error {
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(data)
	}
	address := s.link.URL + path
	if len(query) > 0 {
		address += "?" + query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, address, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+s.link.Token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := s.client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("%w: %v", ErrUnreachable, err)
	}
	defer resp.Body.Close()
	if err := checkMode(resp); err != nil {
		s.log.Error("the server is not a media server", "err", err)
		return err
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("%w: %v", ErrUnreachable, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &StatusError{Code: resp.StatusCode, Body: data}
	}
	if out == nil || len(data) == 0 {
		return nil
	}
	if err := json.Unmarshal(data, out); err != nil {
		return fmt.Errorf("server's answer to %s: %w", path, err)
	}
	return nil
}

// Forward passes r on to path on the server, with query in place of its own
// when query is not nil, and its answer back as it comes: a stream, a range
// of one, or an addon list.
func (s *Server) Forward(w http.ResponseWriter, r *http.Request, path string, query url.Values) {
	out := r.Clone(r.Context())
	out.URL.Path, out.URL.RawPath = path, ""
	if query != nil {
		out.URL.RawQuery = query.Encode()
	}
	s.proxy.ServeHTTP(w, out)
}

// Remember keeps what the server calls a title.
func (s *Server) Remember(serverID string, title Title) {
	if serverID == "" || title.IMDb == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.byServer[serverID] = title
	s.byIMDb[title.IMDb] = serverID
}

// RememberItem keeps the ids of an item the server answered with.
func (s *Server) RememberItem(item catalog.MediaItem) {
	s.Remember(item.ID, Title{IMDb: item.IMDbID(), Kind: item.Kind})
}

// ServerID is the server's id for a title, when one was seen.
func (s *Server) ServerID(imdb string) (string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	id, ok := s.byIMDb[imdb]
	return id, ok
}

// TitleOf is the title behind a server id, when one was seen.
func (s *Server) TitleOf(serverID string) (Title, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	title, ok := s.byServer[serverID]
	return title, ok
}

// Find is the server's item for a title, which it adds to its catalogue the
// first time, as a shared link does.
func (s *Server) Find(ctx context.Context, kind catalog.Kind, imdb string) (catalog.MediaItem, error) {
	var item catalog.MediaItem
	err := s.Do(ctx, http.MethodGet, "/api/v1/find", url.Values{"imdb": {imdb}, "kind": {string(kind)}}, nil, &item)
	if err != nil {
		return catalog.MediaItem{}, err
	}
	s.RememberItem(item)
	return item, nil
}

// Item is the server's item behind its id.
func (s *Server) Item(ctx context.Context, serverID string) (catalog.MediaItem, error) {
	s.mu.Lock()
	known := s.unknown[serverID]
	s.mu.Unlock()
	if known != nil {
		return catalog.MediaItem{}, known
	}
	var item catalog.MediaItem
	if err := s.Do(ctx, http.MethodGet, "/api/v1/items/"+url.PathEscape(serverID), nil, nil, &item); err != nil {
		if se, ok := errors.AsType[*StatusError](err); ok && se.Code == http.StatusNotFound {
			s.mu.Lock()
			s.unknown[serverID] = err
			s.mu.Unlock()
		}
		return catalog.MediaItem{}, err
	}
	s.RememberItem(item)
	return item, nil
}

func writeError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

// Unauthorized says whether err is the server refusing the credential.
func Unauthorized(err error) bool {
	se, ok := errors.AsType[*StatusError](err)
	return ok && se.Code == http.StatusUnauthorized
}

// itoa is for query values.
func itoa(n int) string { return strconv.Itoa(n) }
