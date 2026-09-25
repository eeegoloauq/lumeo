package local

import (
	"context"
	"fmt"
	"io"
	"path/filepath"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

type Backend struct{}

func (Backend) Scheme() string { return "file" }
func (Backend) Close() error   { return nil }
func (Backend) Start(_ context.Context, loc sources.Locator, _ string) (acquire.Task, error) {
	if !filepath.IsAbs(loc.Path) {
		return nil, fmt.Errorf("local: path must be absolute")
	}
	f, err := OpenVideo(loc.Path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	return file{path: loc.Path, size: info.Size()}, nil
}

type file struct {
	path string
	size int64
}

func (f file) Progress() acquire.Progress                      { return acquire.Progress{Completed: f.size, Total: f.size} }
func (f file) File() (acquire.File, bool)                      { return f, true }
func (file) Close() error                                      { return nil }
func (f file) Path() string                                    { return f.path }
func (f file) Size() int64                                     { return f.size }
func (f file) Head() int64                                     { return f.size }
func (f file) Open(context.Context) (io.ReadSeekCloser, error) { return OpenVideo(f.path) }
