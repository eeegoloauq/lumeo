package torrent

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

// overreadingReader stands in for the anacrolix reader: it happily returns
// data past the file it was opened on, which is the behaviour boundedReader
// exists to hide.
type overreadingReader struct{ *strings.Reader }

func (overreadingReader) Close() error { return nil }

func TestBoundedReaderStopsAtFileEnd(t *testing.T) {
	const file = "episode-one"
	inner := overreadingReader{strings.NewReader(file + "next-file-in-the-pack")}
	r := &boundedReader{reader: inner, size: int64(len(file))}

	got, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !bytes.Equal(got, []byte(file)) {
		t.Errorf("read %q, want %q", got, file)
	}
	if n, err := r.Read(make([]byte, 8)); n != 0 || err != io.EOF {
		t.Errorf("past the end: n=%d err=%v", n, err)
	}
}

func TestBoundedReaderSeekResyncsTheLimit(t *testing.T) {
	const file = "0123456789"
	inner := overreadingReader{strings.NewReader(file + "beyond")}
	r := &boundedReader{reader: inner, size: int64(len(file))}

	if _, err := r.Seek(6, io.SeekStart); err != nil {
		t.Fatalf("seek: %v", err)
	}
	got, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read after seek: %v", err)
	}
	if string(got) != "6789" {
		t.Errorf("read %q, want %q", got, "6789")
	}
}
