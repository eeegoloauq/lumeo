package torrent

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sync"

	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/segments"
	"github.com/anacrolix/torrent/storage"
)

// fileStorage keeps a torrent's files on disk the way anacrolix's file storage
// lays them out — the same paths, a .part name until every piece of a file is
// in, the same completion database — so downloads started before it carry on.
//
// It exists because that storage, in the version we use, maps every file it
// touches into memory at its full length and never lets go, not even when the
// torrent is dropped. On Linux that only leaks until the core stops. On Windows
// a mapped or open file cannot be deleted, so freeing a download failed while
// the core ran, and a file made full length on NTFS is not sparse: writing its
// last piece, which is asked for first, zero-fills everything before it. Here a
// file is sparse, each has one handle, and dropping the torrent closes them.
type fileStorage struct {
	dir        string
	completion storage.PieceCompletion
}

var _ storage.ClientImplCloser = (*fileStorage)(nil)

func newFileStorage(dir string) (*fileStorage, error) {
	completion, err := storage.NewDefaultPieceCompletionForDir(dir)
	if err != nil {
		return nil, fmt.Errorf("torrent: open piece completion: %w", err)
	}
	return &fileStorage{dir: dir, completion: completion}, nil
}

func (s *fileStorage) Close() error { return s.completion.Close() }

func (s *fileStorage) OpenTorrent(_ context.Context, info *metainfo.Info, infoHash metainfo.Hash) (storage.TorrentImpl, error) {
	t := &torrentStorage{
		info:       info,
		infoHash:   infoHash,
		completion: s.completion,
		index:      info.FileSegmentsIndex(),
	}
	for i, fi := range info.UpvertedFiles() {
		var parts []string
		if name := info.BestName(); name != metainfo.NoName {
			parts = append(parts, name)
		}
		path, ok := safeFilePath(s.dir, filepath.Join(append(parts, fi.BestPath()...)...))
		if !ok {
			return storage.TorrentImpl{}, fmt.Errorf("torrent: file %d escapes %q", i, s.dir)
		}
		// No piece holds an empty file, so nothing else would create it.
		if fi.Length == 0 {
			if err := storage.CreateNativeZeroLengthFile(path); err != nil {
				return storage.TorrentImpl{}, fmt.Errorf("torrent: create %q: %w", path, err)
			}
		}
		t.files = append(t.files, &storedFile{
			path:   path,
			offset: fi.TorrentOffset,
			length: fi.Length,
			begin:  fi.BeginPieceIndex(info.PieceLength),
			end:    fi.EndPieceIndex(info.PieceLength),
		})
	}
	for _, f := range t.files {
		if err := t.settle(f); err != nil {
			return storage.TorrentImpl{}, err
		}
	}
	return storage.TorrentImpl{Piece: t.piece, Close: t.close}, nil
}

type torrentStorage struct {
	info       *metainfo.Info
	infoHash   metainfo.Hash
	completion storage.PieceCompletion
	index      segments.Index
	files      []*storedFile
}

var errStorageClosed = errors.New("torrent: storage is closed")

// storedFile is one file of the torrent and the handle it is read and written
// through. The handle is shared by every read and write; mu is taken for
// writing only to open, close or rename it.
type storedFile struct {
	path       string
	offset     int64 // in the torrent
	length     int64
	begin, end int // pieces holding any of it

	mu     sync.RWMutex
	handle *os.File
	closed bool

	countMu sync.Mutex
	missing int
	counted bool
}

func (f *storedFile) partPath() string { return f.path + ".part" }

// current is where the file's bytes are: its own name once complete, the .part
// name until then.
func (f *storedFile) current() string {
	if _, err := os.Stat(f.path); err == nil {
		return f.path
	}
	return f.partPath()
}

// size is the length of the file under its current name. It holds the lock
// rename does, or it could see neither name while the file moves between them.
func (f *storedFile) size() (int64, error) {
	f.mu.RLock()
	defer f.mu.RUnlock()
	info, err := os.Stat(f.current())
	if err != nil {
		return 0, err
	}
	return info.Size(), nil
}

// use runs op on the file's handle, opening it first if need be. A file that
// is not there yet is created only for a write; a read of it is a short read.
func (f *storedFile) use(write bool, op func(*os.File) (int, error)) (int, error) {
	f.mu.RLock()
	if f.handle != nil {
		defer f.mu.RUnlock()
		return op(f.handle)
	}
	f.mu.RUnlock()

	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return 0, errStorageClosed
	}
	if f.handle == nil {
		h, err := openData(f.current(), write)
		if errors.Is(err, fs.ErrNotExist) && !write {
			return 0, io.EOF
		}
		if err != nil {
			return 0, err
		}
		f.handle = h
	}
	return op(f.handle)
}

// rename moves the file between its two names, with its handle closed: Windows
// renames an open file only if every handle on it allows that.
func (f *storedFile) rename(from, to string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return errStorageClosed
	}
	if err := f.closeHandle(); err != nil {
		return err
	}
	if err := os.Rename(from, to); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

func (f *storedFile) closeHandle() error {
	if f.handle == nil {
		return nil
	}
	err := f.handle.Close()
	f.handle = nil
	return err
}

func (t *torrentStorage) close() error {
	var err error
	for _, f := range t.files {
		f.mu.Lock()
		f.closed = true
		err = errors.Join(err, f.closeHandle())
		f.mu.Unlock()
	}
	return err
}

func (t *torrentStorage) piece(p metainfo.Piece) storage.PieceImpl {
	return &storedPiece{t: t, p: p}
}

type storedPiece struct {
	t *torrentStorage
	p metainfo.Piece
}

func (p *storedPiece) key() metainfo.PieceKey {
	return metainfo.PieceKey{InfoHash: p.t.infoHash, Index: p.p.Index()}
}

// each calls fn for the part of every file the n bytes at off in the piece
// fall in, in order, and stops at the first error or short count.
func (p *storedPiece) each(off int64, n int, fn func(f *storedFile, fileOff int64, begin, length int) (int, error)) (int, error) {
	done := 0
	for i, e := range p.t.index.LocateIter(segments.Extent{Start: p.p.Offset() + off, Length: int64(n)}) {
		m, err := fn(p.t.files[i], e.Start, done, int(e.Length))
		done += m
		if err != nil {
			return done, err
		}
		if m < int(e.Length) {
			return done, io.EOF
		}
	}
	return done, nil
}

// ReadAt answers a short read with io.EOF, as a missing or short file is: the
// caller takes that for data lost and fetches the piece again.
func (p *storedPiece) ReadAt(b []byte, off int64) (int, error) {
	return p.each(off, len(b), func(f *storedFile, at int64, begin, length int) (int, error) {
		n, err := f.use(false, func(h *os.File) (int, error) { return h.ReadAt(b[begin:begin+length], at) })
		if err == io.EOF && n == length {
			err = nil
		}
		return n, err
	})
}

func (p *storedPiece) WriteAt(b []byte, off int64) (int, error) {
	return p.each(off, len(b), func(f *storedFile, at int64, begin, length int) (int, error) {
		return f.use(true, func(h *os.File) (int, error) { return h.WriteAt(b[begin:begin+length], at) })
	})
}

// MarkComplete records the piece after its bytes are on disk, so a crash never
// leaves a record of data that is not there, and gives a file whose every
// piece is in its own name.
func (p *storedPiece) MarkComplete() error {
	for f := range p.files() {
		if _, err := f.use(false, func(h *os.File) (int, error) { return 0, h.Sync() }); err != nil && err != io.EOF {
			return err
		}
	}
	changed, err := p.set(true)
	if err != nil || !changed {
		return err
	}
	for f := range p.files() {
		whole, err := p.t.count(f, -1)
		if err != nil {
			return err
		}
		if whole {
			if err := f.rename(f.partPath(), f.path); err != nil {
				return fmt.Errorf("torrent: promote %q: %w", f.path, err)
			}
		}
	}
	return nil
}

// MarkNotComplete takes a file with a piece gone bad back to its .part name:
// a file under its own name is one the library treats as whole.
func (p *storedPiece) MarkNotComplete() error {
	changed, err := p.set(false)
	if err != nil || !changed {
		return err
	}
	for f := range p.files() {
		if _, err := p.t.count(f, +1); err != nil {
			return err
		}
		if err := f.rename(f.path, f.partPath()); err != nil {
			return fmt.Errorf("torrent: demote %q: %w", f.path, err)
		}
	}
	return nil
}

// set records the piece and says whether that changed the record.
func (p *storedPiece) set(complete bool) (bool, error) {
	c, err := p.t.completion.Get(p.key())
	if err != nil {
		return false, err
	}
	if c.Ok && c.Complete == complete {
		return false, nil
	}
	return true, p.t.completion.Set(p.key(), complete)
}

// Completion is the record, checked against the files: a piece recorded as
// complete whose file is gone or too short, deleted or cut outside the app,
// is not.
func (p *storedPiece) Completion() storage.Completion {
	c, err := p.t.completion.Get(p.key())
	if err != nil {
		return storage.Completion{Err: err}
	}
	if !c.Ok || !c.Complete {
		return c
	}
	for i, e := range p.t.index.LocateIter(segments.Extent{Start: p.p.Offset(), Length: p.p.Length()}) {
		f := p.t.files[i]
		size, err := f.size()
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			return storage.Completion{Err: err}
		}
		if size < e.End() {
			if err := p.t.lost(f, size); err != nil {
				return storage.Completion{Err: err}
			}
			return storage.Completion{Ok: true}
		}
	}
	return c
}

// lost records every piece of f from size on as missing, not only the one
// that found it short: a piece fetched again regrows the file over holes a
// size check cannot tell from data, and each piece has to count towards the
// file again.
func (t *torrentStorage) lost(f *storedFile, size int64) error {
	for i := int((f.offset + size) / t.info.PieceLength); i < f.end; i++ {
		if err := (&storedPiece{t: t, p: t.info.Piece(i)}).MarkNotComplete(); err != nil {
			return err
		}
	}
	return nil
}

func (p *storedPiece) files() func(func(*storedFile) bool) {
	return func(yield func(*storedFile) bool) {
		for i := range p.t.index.LocateIter(segments.Extent{Start: p.p.Offset(), Length: p.p.Length()}) {
			if !yield(p.t.files[i]) {
				return
			}
		}
	}
}

// settle puts a file under the name its record calls for. The mark methods
// write the record before they rename, and a piece already recorded is not
// marked again, so a crash between the two would leave a whole file under
// .part for good, or one with a piece gone bad under its own name.
func (t *torrentStorage) settle(f *storedFile) error {
	_, errWhole := os.Stat(f.path)
	_, errPart := os.Stat(f.partPath())
	if (errWhole == nil) == (errPart == nil) {
		return nil
	}
	whole, err := t.count(f, 0)
	if err != nil {
		return err
	}
	switch {
	case whole && errPart == nil:
		err = f.rename(f.partPath(), f.path)
	case !whole && errWhole == nil:
		err = f.rename(f.path, f.partPath())
	}
	if err != nil {
		return fmt.Errorf("torrent: settle %q: %w", f.path, err)
	}
	return nil
}

// count keeps how many of a file's pieces are still missing, after one of them
// changed by delta, and says whether none are. It is counted from the record
// the first time, so marking a piece is not a walk over the whole file.
func (t *torrentStorage) count(f *storedFile, delta int) (bool, error) {
	f.countMu.Lock()
	defer f.countMu.Unlock()
	if f.counted {
		f.missing = max(0, f.missing+delta)
		return f.missing == 0, nil
	}
	missing := 0
	for piece := f.begin; piece < f.end; piece++ {
		c, err := t.completion.Get(metainfo.PieceKey{InfoHash: t.infoHash, Index: piece})
		if err != nil {
			return false, err
		}
		if !c.Ok || !c.Complete {
			missing++
		}
	}
	f.missing, f.counted = missing, true
	return missing == 0, nil
}
