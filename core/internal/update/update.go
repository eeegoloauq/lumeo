// Package update tells a client that a newer release has been published.
// It only looks: installing is the package manager's, or the viewer's.
package update

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/egress"
)

// Release is a published version newer than the running one.
type Release struct {
	Version string `json:"version"`
	// URL is the release's page, where its packages are.
	URL string `json:"url"`
	// Notes is the release's AppStream file, which carries the notes of every
	// version up to it with their translations: the client already reads
	// that format for its own notes, in the viewer's language.
	Notes string `json:"notes"`
}

// Checker asks GitHub for the latest release, or the newest of all of them
// betas included. The answer is kept for a day, for each of the two: the
// client asks on every start, and a core that runs for weeks should still
// hear about a release made meanwhile.
type Checker struct {
	version string
	// API and Raw are GitHub's hosts; tests point them elsewhere.
	API, Raw string
	client   *http.Client

	mu    sync.Mutex
	looks [2]look // releases, then betas too
}

type look struct {
	checked time.Time
	latest  *Release
}

const (
	repo  = "eeegoloauq/lumeo"
	fresh = 24 * time.Hour
	// A failed look is tried again sooner than a successful one.
	retry = time.Hour
)

func New(version string) *Checker {
	return &Checker{
		version: version,
		API:     "https://api.github.com",
		Raw:     "https://raw.githubusercontent.com",
		client:  &http.Client{Timeout: 15 * time.Second, Transport: egress.Transport},
	}
}

// Newer returns the latest release when it is newer than the running core,
// and nil when it is not. A build without a release version (a checkout)
// has nothing to compare and never looks.
func (c *Checker) Newer(ctx context.Context, now time.Time, betas bool) (*Release, error) {
	running, ok := parse(c.version)
	if !ok {
		return nil, nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	l := &c.looks[0]
	if betas {
		l = &c.looks[1]
	}
	if !l.checked.IsZero() && now.Sub(l.checked) < fresh {
		return l.latest, nil
	}
	latest, err := c.fetch(ctx, running, betas)
	if err != nil {
		// Counted as a look an hour old at the next day's mark.
		l.checked = now.Add(retry - fresh)
		return nil, err
	}
	l.checked, l.latest = now, latest
	return latest, nil
}

type published struct {
	Tag   string `json:"tag_name"`
	URL   string `json:"html_url"`
	Draft bool   `json:"draft"`
}

func (c *Checker) fetch(ctx context.Context, running [4]int, betas bool) (*Release, error) {
	var release published
	var version [4]int
	if betas {
		// Newest first by date, which a fix to an older line would break,
		// so the highest version of the page is taken instead.
		body, err := c.get(ctx, c.API+"/repos/"+repo+"/releases?per_page=30")
		if err != nil {
			return nil, err
		}
		var all []published
		if err := json.Unmarshal(body, &all); err != nil {
			return nil, fmt.Errorf("update: releases: %w", err)
		}
		for _, r := range all {
			if v, ok := parse(r.Tag); ok && !r.Draft && newer(v, version) {
				release, version = r, v
			}
		}
	} else {
		body, err := c.get(ctx, c.API+"/repos/"+repo+"/releases/latest")
		if err != nil {
			return nil, err
		}
		if err := json.Unmarshal(body, &release); err != nil {
			return nil, fmt.Errorf("update: latest release: %w", err)
		}
		var ok bool
		if version, ok = parse(release.Tag); !ok {
			return nil, fmt.Errorf("update: latest release has tag %q", release.Tag)
		}
	}
	if !newer(version, running) {
		return nil, nil
	}
	notes, err := c.get(ctx, c.Raw+"/"+repo+"/"+release.Tag+"/client/assets/dev.lumeo.lumeo.metainfo.xml")
	if err != nil {
		return nil, err
	}
	return &Release{
		Version: strings.TrimPrefix(release.Tag, "v"),
		URL:     release.URL,
		Notes:   string(notes),
	}, nil
}

func (c *Checker) get(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", egress.UserAgent)
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("update: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, errors.New("update: " + url + " answered " + resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 1<<20))
}

// parse reads "0.1.68", "v0.1.68" or a beta, "0.1.68-beta.2". The fourth
// number is the beta's, and a release's is above every beta of it.
func parse(version string) ([4]int, bool) {
	parts := [4]int{3: math.MaxInt}
	version, beta, isBeta := strings.Cut(strings.TrimPrefix(version, "v"), "-")
	fields := strings.Split(version, ".")
	if len(fields) != 3 {
		return parts, false
	}
	if isBeta {
		number, ok := strings.CutPrefix(beta, "beta.")
		if !ok {
			return parts, false
		}
		fields = append(fields, number)
	}
	for i, f := range fields {
		n, err := strconv.Atoi(f)
		if err != nil || n < 0 {
			return parts, false
		}
		parts[i] = n
	}
	return parts, true
}

func newer(a, b [4]int) bool {
	for i := range a {
		if a[i] != b[i] {
			return a[i] > b[i]
		}
	}
	return false
}
