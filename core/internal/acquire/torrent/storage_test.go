package torrent

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/storage"
)

const testPiece = 16 << 10

// openTestTorrent opens a two-file torrent, 2.5 and 1.5 pieces long, in dir.
func openTestTorrent(t *testing.T, dir string) (*storage.Torrent, *metainfo.Info, *fileStorage) {
	t.Helper()
	info := &metainfo.Info{
		Name:        "Show",
		PieceLength: testPiece,
		Files: []metainfo.FileInfo{
			{Path: []string{"e01.mkv"}, Length: testPiece * 5 / 2},
			{Path: []string{"e02.mkv"}, Length: testPiece * 3 / 2},
		},
		Pieces: make([]byte, 20*4),
	}
	fs, err := newFileStorage(dir)
	if err != nil {
		t.Fatalf("open storage: %v", err)
	}
	tor, err := storage.NewClient(fs).OpenTorrent(context.Background(), info, metainfo.Hash{1})
	if err != nil {
		t.Fatalf("open torrent: %v", err)
	}
	return tor, info, fs
}

func pieceData(i int) []byte { return bytes.Repeat([]byte{byte('a' + i)}, testPiece) }

func writePiece(t *testing.T, tor *storage.Torrent, info *metainfo.Info, i int) {
	t.Helper()
	p := tor.Piece(info.Piece(i))
	data := pieceData(i)[:info.Piece(i).Length()]
	if n, err := p.WriteAt(data, 0); err != nil || n != len(data) {
		t.Fatalf("write piece %d: %d, %v", i, n, err)
	}
	if err := p.MarkComplete(); err != nil {
		t.Fatalf("mark piece %d complete: %v", i, err)
	}
}

func TestStorageKeepsAFileUnderPartUntilEveryPieceIsIn(t *testing.T) {
	dir := t.TempDir()
	tor, info, fs := openTestTorrent(t, dir)
	defer fs.Close()
	defer tor.Close()
	first := filepath.Join(dir, "Show", "e01.mkv")

	// The last piece of the first file comes first, as the ends are asked
	// for first; it is shared with the second file.
	writePiece(t, tor, info, 2)
	writePiece(t, tor, info, 0)
	if _, err := os.Stat(first + ".part"); err != nil {
		t.Fatalf("an incomplete file is not under .part: %v", err)
	}
	if _, err := os.Stat(first); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("an incomplete file is under its own name: %v", err)
	}

	writePiece(t, tor, info, 1)
	data, err := os.ReadFile(first)
	if err != nil {
		t.Fatalf("a complete file is not under its own name: %v", err)
	}
	want := append(append(pieceData(0), pieceData(1)...), pieceData(2)[:testPiece/2]...)
	if !bytes.Equal(data, want) {
		t.Fatal("the complete file does not hold what was written")
	}
	if _, err := os.Stat(filepath.Join(dir, "Show", "e02.mkv")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("the second file is complete with one of its two pieces")
	}

	// Read back across the boundary between the files.
	got := make([]byte, testPiece)
	if n, err := tor.Piece(info.Piece(2)).ReadAt(got, 0); err != nil || n != testPiece {
		t.Fatalf("read the shared piece: %d, %v", n, err)
	}
	if !bytes.Equal(got, pieceData(2)) {
		t.Fatal("the shared piece does not read back as written")
	}
}

func TestStorageLetsGoOfItsFilesWhenTheTorrentCloses(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("reads the open files from /proc")
	}
	dir := t.TempDir()
	tor, info, fs := openTestTorrent(t, dir)
	writePiece(t, tor, info, 0)
	writePiece(t, tor, info, 3)
	if held := heldUnder(t, dir); held == 0 {
		t.Fatal("no file is open while the torrent is; the check sees nothing")
	}
	if err := tor.Close(); err != nil {
		t.Fatalf("close torrent: %v", err)
	}
	if err := fs.Close(); err != nil {
		t.Fatalf("close storage: %v", err)
	}
	if held := heldUnder(t, dir); held != 0 {
		t.Fatalf("%d files under the download are still open or mapped", held)
	}
	if _, err := tor.Piece(info.Piece(0)).WriteAt([]byte{1}, 0); !errors.Is(err, errStorageClosed) {
		t.Fatalf("a write after close: %v", err)
	}
}

// heldUnder counts this process's descriptors and mappings of files under dir.
func heldUnder(t *testing.T, dir string) int {
	t.Helper()
	held := 0
	fds, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		t.Fatalf("list descriptors: %v", err)
	}
	for _, fd := range fds {
		if target, err := os.Readlink(filepath.Join("/proc/self/fd", fd.Name())); err == nil && strings.HasPrefix(target, dir) {
			held++
		}
	}
	maps, err := os.ReadFile("/proc/self/maps")
	if err != nil {
		t.Fatalf("read mappings: %v", err)
	}
	held += strings.Count(string(maps), dir)
	return held
}

func TestStorageDoesNotTrustARecordOfAFileDeletedOutsideIt(t *testing.T) {
	dir := t.TempDir()
	tor, info, fs := openTestTorrent(t, dir)
	for i := range 3 {
		writePiece(t, tor, info, i)
	}
	tor.Close()
	fs.Close()
	first := filepath.Join(dir, "Show", "e01.mkv")
	if err := os.Remove(first); err != nil {
		t.Fatalf("delete the file: %v", err)
	}

	tor, info, fs = openTestTorrent(t, dir)
	defer fs.Close()
	defer tor.Close()
	if c := tor.Piece(info.Piece(0)).Completion(); !c.Ok || c.Complete {
		t.Fatalf("a piece of a deleted file = %+v, want known and not complete", c)
	}
	// And it counts again: the file is whole once every piece is back.
	for i := range 3 {
		writePiece(t, tor, info, i)
	}
	if _, err := os.Stat(first); err != nil {
		t.Fatalf("the file fetched again is not under its own name: %v", err)
	}
}

func TestStorageForgetsEveryPieceOfAFileDeletedWhileOpen(t *testing.T) {
	dir := t.TempDir()
	tor, info, fs := openTestTorrent(t, dir)
	defer fs.Close()
	defer tor.Close()
	for i := range 3 {
		writePiece(t, tor, info, i)
	}
	if err := os.Remove(filepath.Join(dir, "Show", "e01.mkv")); err != nil {
		t.Fatalf("delete the file: %v", err)
	}
	if c := tor.Piece(info.Piece(0)).Completion(); c.Complete {
		t.Fatalf("a piece of a deleted file = %+v, want not complete", c)
	}
	// The last piece back makes the file full length again, over a hole
	// where piece 1 was.
	writePiece(t, tor, info, 2)
	if c := tor.Piece(info.Piece(1)).Completion(); !c.Ok || c.Complete {
		t.Fatalf("a piece in the hole = %+v, want known and not complete", c)
	}
}

func TestStorageCreatesAnEmptyFile(t *testing.T) {
	dir := t.TempDir()
	info := &metainfo.Info{
		Name:        "Film",
		PieceLength: testPiece,
		Files: []metainfo.FileInfo{
			{Path: []string{"film.mkv"}, Length: testPiece},
			{Path: []string{"empty.txt"}},
		},
		Pieces: make([]byte, 20),
	}
	fs, err := newFileStorage(dir)
	if err != nil {
		t.Fatalf("open storage: %v", err)
	}
	defer fs.Close()
	tor, err := storage.NewClient(fs).OpenTorrent(context.Background(), info, metainfo.Hash{1})
	if err != nil {
		t.Fatalf("open torrent: %v", err)
	}
	defer tor.Close()
	if st, err := os.Stat(filepath.Join(dir, "Film", "empty.txt")); err != nil || st.Size() != 0 {
		t.Fatalf("the empty file: %v, %v", st, err)
	}
}

func TestStorageReadsWhatAnEarlierVersionLeft(t *testing.T) {
	dir := t.TempDir()
	part := filepath.Join(dir, "Show", "e01.mkv.part")
	if err := os.MkdirAll(filepath.Dir(part), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(part, pieceData(0), 0o600); err != nil {
		t.Fatal(err)
	}
	tor, info, fs := openTestTorrent(t, dir)
	defer fs.Close()
	defer tor.Close()
	got := make([]byte, testPiece)
	if _, err := tor.Piece(info.Piece(0)).ReadAt(got, 0); err != nil && err != io.EOF {
		t.Fatalf("read a .part file: %v", err)
	}
	if !bytes.Equal(got, pieceData(0)) {
		t.Fatal("a .part file does not read back")
	}
	if n, err := tor.Piece(info.Piece(1)).ReadAt(got, 0); err != io.EOF {
		t.Fatalf("a read past what is on disk = %d, %v; want io.EOF", n, err)
	}
}

// A crash between writing the record and renaming the file leaves the name
// behind the record; nothing marks those pieces again, so opening puts it right.
func TestStorageSettlesANameACrashLeftBehindTheRecord(t *testing.T) {
	dir := t.TempDir()
	first := filepath.Join(dir, "Show", "e01.mkv")
	tor, info, fs := openTestTorrent(t, dir)
	for i := range 3 {
		writePiece(t, tor, info, i)
	}
	tor.Close()
	fs.Close()

	// Recorded complete, still under .part.
	if err := os.Rename(first, first+".part"); err != nil {
		t.Fatal(err)
	}
	tor, info, fs = openTestTorrent(t, dir)
	if _, err := os.Stat(first); err != nil {
		t.Fatalf("a whole file left under .part is not promoted: %v", err)
	}
	tor.Close()

	// Recorded missing a piece, still under its own name.
	if err := fs.completion.Set(metainfo.PieceKey{InfoHash: metainfo.Hash{1}, Index: 1}, false); err != nil {
		t.Fatal(err)
	}
	fs.Close()
	tor, _, fs = openTestTorrent(t, dir)
	defer fs.Close()
	defer tor.Close()
	if _, err := os.Stat(first + ".part"); err != nil {
		t.Fatalf("a file missing a piece is not taken back to .part: %v", err)
	}
	if _, err := os.Stat(first); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a file missing a piece is under its own name: %v", err)
	}
}
