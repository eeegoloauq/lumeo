package subtitles

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// hashChunk is fixed by the OpenSubtitles hash: 64 KiB from each end.
const hashChunk = 64 << 10

// ErrTooSmall means the file is shorter than the two chunks the hash is made
// of. Nothing is wrong with it; it just cannot be identified this way.
var ErrTooSmall = errors.New("subtitles: file is too small to hash")

// Hash computes the OpenSubtitles hash of a video: the file size plus every
// 64-bit little-endian word of the first and last 64 KiB, added with
// wraparound. It reads 128 KiB and identifies the exact encode, which is why
// every subtitle database in existence is keyed by it.
//
// On a download that is still arriving, reading the tail asks the swarm for
// pieces playback does not need yet — 64 KiB of them. That is the price of
// getting subtitles that are in sync from the first minute.
func Hash(r io.ReadSeeker, size int64) (string, error) {
	if size < hashChunk*2 {
		return "", ErrTooSmall
	}
	sum := uint64(size)
	buf := make([]byte, hashChunk)

	if _, err := r.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	if _, err := io.ReadFull(r, buf); err != nil {
		return "", fmt.Errorf("subtitles: read head: %w", err)
	}
	sum += chunkSum(buf)

	if _, err := r.Seek(size-hashChunk, io.SeekStart); err != nil {
		return "", err
	}
	if _, err := io.ReadFull(r, buf); err != nil {
		return "", fmt.Errorf("subtitles: read tail: %w", err)
	}
	sum += chunkSum(buf)

	return fmt.Sprintf("%016x", sum), nil
}

func chunkSum(buf []byte) uint64 {
	var sum uint64
	for i := 0; i+8 <= len(buf); i += 8 {
		sum += binary.LittleEndian.Uint64(buf[i:])
	}
	return sum
}
