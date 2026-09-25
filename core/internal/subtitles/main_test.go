package subtitles

import (
	"os"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/egress"
)

// The fake addons and image hosts here listen on loopback, which the core
// refuses to fetch what an addon names from.
func TestMain(m *testing.M) {
	restore := egress.AllowPrivateAddresses()
	code := m.Run()
	restore()
	os.Exit(code)
}
