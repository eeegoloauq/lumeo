package local

import (
	"errors"
	"fmt"
	"io"
	"os"
)

// ErrNotVideo means the bytes at a path are not a video container.
var ErrNotVideo = errors.New("local: not a video file")

// OpenVideo opens path for reading if what it holds is a video, and is the
// only way the core opens a file it was handed by path. The name proves
// nothing: a symlink called film.mkv can point anywhere, and the API has no
// authentication yet, so without this whoever reaches it could have the core
// read them any file this user can. The container is checked on the open
// file, the one that is then served, so swapping the path afterwards changes
// nothing.
func OpenVideo(path string) (*os.File, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	if err := checkVideo(f); err != nil {
		f.Close()
		return nil, fmt.Errorf("%w: %s", err, path)
	}
	return f, nil
}

func checkVideo(f *os.File) error {
	info, err := f.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return ErrNotVideo
	}
	var head [200]byte
	n, err := f.ReadAt(head[:], 0)
	if err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	if !videoContainer(head[:n]) {
		return ErrNotVideo
	}
	return nil
}

// videoContainer recognises the containers video files come in by their
// first bytes, as file(1) does.
func videoContainer(b []byte) bool {
	at := func(offset int, sig string) bool {
		return len(b) >= offset+len(sig) && string(b[offset:offset+len(sig)]) == sig
	}
	switch {
	case at(0, "\x1a\x45\xdf\xa3"): // EBML: Matroska, WebM
		return true
	case at(4, "ftyp"), at(4, "moov"), at(4, "mdat"), at(4, "wide"), at(4, "free"), at(4, "skip"): // ISO BMFF, QuickTime
		return true
	case at(0, "RIFF") && at(8, "AVI "):
		return true
	case at(0, "\x30\x26\xb2\x75\x8e\x66\xcf\x11"): // ASF: WMV
		return true
	case at(0, "FLV"), at(0, "OggS"):
		return true
	case at(0, "\x00\x00\x01\xba"), at(0, "\x00\x00\x01\xb3"): // MPEG program stream, elementary video
		return true
	case len(b) > 188 && b[0] == 0x47 && b[188] == 0x47: // MPEG-TS
		return true
	case len(b) > 196 && b[4] == 0x47 && b[196] == 0x47: // M2TS: TS with a 4-byte timestamp
		return true
	}
	return false
}
