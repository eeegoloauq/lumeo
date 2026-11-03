package acquire

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// FolderFor is where under the download root a download of a title goes,
// laid out the way media servers read a library: "Title (Year)" for a film,
// "Title (Year)/Season 01" for an episode, "Specials" for season 0. Only these
// folders are ours: the download's own directory goes inside, and the
// torrent's files inside that keep their names, which seeding needs. A title
// with nothing left of its name once made safe gets none.
func FolderFor(title string, year int, series bool, season int) string {
	name := safeName(title)
	if name == "" {
		return ""
	}
	if year > 0 {
		name += " (" + strconv.Itoa(year) + ")"
	}
	if reserved(name) {
		name += "_"
	}
	switch {
	case !series:
		return name
	case season == 0:
		return filepath.Join(name, "Specials")
	default:
		return filepath.Join(name, fmt.Sprintf("Season %02d", season))
	}
}

// longestName keeps a title's folder clear of Windows' 260-character paths,
// with the torrent's own names still to come under it.
const longestName = 80

// safeName is title as a folder name on every system, since a disk of
// downloads moves between them: what Windows refuses in a name goes, a colon
// as a dash ("Star Wars - Andor"), and so do the dots and spaces it drops
// from an end and a leading dot, which hides a folder elsewhere.
func safeName(title string) string {
	var b strings.Builder
	for _, r := range title {
		switch {
		case r < 0x20 || r == 0x7f:
		case r == ':':
			b.WriteString(" - ")
		case strings.ContainsRune(`<>"/\|?*`, r):
			b.WriteRune(' ')
		default:
			b.WriteRune(r)
		}
	}
	name := strings.Trim(strings.Join(strings.Fields(b.String()), " "), ". ")
	if runes := []rune(name); len(runes) > longestName {
		name = strings.TrimRight(string(runes[:longestName]), ". ")
	}
	return name
}

// reserved says whether Windows keeps name for a device, with or without an
// extension after it.
func reserved(name string) bool {
	base, _, _ := strings.Cut(strings.ToUpper(name), ".")
	switch strings.TrimRight(base, " ") {
	case "CON", "PRN", "AUX", "NUL":
		return true
	}
	if len(base) == 4 && (strings.HasPrefix(base, "COM") || strings.HasPrefix(base, "LPT")) {
		return base[3] >= '1' && base[3] <= '9'
	}
	return false
}

// prune takes out the folders a download was made in once nothing is left
// in them, the season's and then the title's: never the root above them,
// nor one that has anything else in it.
func prune(row Download) {
	if row.Folder == "" {
		return
	}
	folder := filepath.Clean(row.Folder)
	dir := filepath.Dir(absolute(row.Dir))
	// Only where the download's directory was made: a row whose directory
	// moved since names folders that are not these.
	if !strings.HasSuffix(dir, string(filepath.Separator)+folder) {
		return
	}
	for range strings.Split(filepath.ToSlash(folder), "/") {
		if err := os.Remove(dir); err != nil && !os.IsNotExist(err) {
			return
		}
		dir = filepath.Dir(dir)
	}
}
