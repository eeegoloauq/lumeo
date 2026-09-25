package subtitles

import (
	"bytes"
	"errors"
	"testing"
)

// The expected value comes from an independent implementation of the same
// algorithm, because a hash that only agrees with itself identifies nothing:
// the whole point is that OpenSubtitles computes the same number.
func TestHashMatchesTheOpenSubtitlesAlgorithm(t *testing.T) {
	data := make([]byte, 200000)
	for i := range data {
		data[i] = byte((i*7 + 3) % 251)
	}
	got, err := Hash(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	if want := "e6ed0e283146465f"; got != want {
		t.Errorf("hash: got %q, want %q", got, want)
	}
}

// The hash reads both ends, so a file shorter than both is not hashable —
// which is a fact about the file, not a failure of the lookup.
func TestHashRefusesFilesTooSmall(t *testing.T) {
	data := make([]byte, hashChunk)
	if _, err := Hash(bytes.NewReader(data), int64(len(data))); !errors.Is(err, ErrTooSmall) {
		t.Errorf("got %v, want ErrTooSmall", err)
	}
}

// Only the two 64 KiB chunks may be read: on a download still arriving, every
// other byte is a piece the swarm has not been asked for.
func TestHashReadsOnlyBothEnds(t *testing.T) {
	data := make([]byte, 4<<20)
	counted := &countingReader{Reader: bytes.NewReader(data)}
	if _, err := Hash(counted, int64(len(data))); err != nil {
		t.Fatalf("hash: %v", err)
	}
	if counted.read != 2*hashChunk {
		t.Errorf("read %d bytes, want %d", counted.read, 2*hashChunk)
	}
}

type countingReader struct {
	*bytes.Reader
	read int
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.Reader.Read(p)
	c.read += n
	return n, err
}
