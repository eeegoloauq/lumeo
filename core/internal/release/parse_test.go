package release

import "testing"

func TestParse(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want Info
	}{
		{
			name: "anime fansub",
			in:   "[Erai-raws] Re:Zero kara Hajimeru Isekai Seikatsu 4th Season - 14 [1080p][Multiple Subtitle][HEVC][10bit]",
			want: Info{Group: "Erai-raws", Season: 4, Episode: 14, Resolution: "1080p", VideoCodec: "HEVC", BitDepth: 10},
		},
		{
			name: "scene series",
			in:   "Severance.S02E03.1080p.WEB-DL.DDP5.1.H.264-NTb",
			want: Info{Season: 2, Episode: 3, Resolution: "1080p", Source: "WEB-DL", AudioCodec: "EAC3", Channels: "5.1", VideoCodec: "AVC", Group: "NTb"},
		},
		{
			name: "uhd remux",
			in:   "Dune Part Two 2024 2160p UHD BluRay REMUX HDR10+ DV TrueHD Atmos 7.1-FraMeSToR",
			want: Info{Year: 2024, Resolution: "2160p", Source: "BluRay", Remux: true, AudioCodec: "TrueHD", Channels: "7.1", Atmos: true, Group: "FraMeSToR"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := Parse(tc.in)
			check := func(field string, want, have any) {
				t.Helper()
				if want != have {
					t.Errorf("%s: want %v, got %v", field, want, have)
				}
			}
			check("season", tc.want.Season, got.Season)
			check("episode", tc.want.Episode, got.Episode)
			check("year", tc.want.Year, got.Year)
			check("resolution", tc.want.Resolution, got.Resolution)
			check("source", tc.want.Source, got.Source)
			check("videoCodec", tc.want.VideoCodec, got.VideoCodec)
			check("audioCodec", tc.want.AudioCodec, got.AudioCodec)
			check("channels", tc.want.Channels, got.Channels)
			check("bitDepth", tc.want.BitDepth, got.BitDepth)
			check("atmos", tc.want.Atmos, got.Atmos)
			check("remux", tc.want.Remux, got.Remux)
			check("group", tc.want.Group, got.Group)
		})
	}
}

// A local file is looked up in the catalogue by its title, so the title has to
// be the show's name alone: no group tag in front, no separator behind.
func TestParseTitle(t *testing.T) {
	for in, want := range map[string]string{
		"[FLE] Re ZERO Starting Life in Another World - S04E17 (WEB 1080p HEVC E-AC-3) [1D7238F4].mkv": "Re ZERO Starting Life in Another World",
		"Breaking.Bad.S01E02.720p.BluRay.x264-DEMAND.mkv":                                              "Breaking Bad",
		"Dune Part Two (2024).mkv":                                                                     "Dune Part Two",
		"Severance.S02E03.1080p.WEB-DL.DDP5.1.H.264-NTb":                                               "Severance",
	} {
		if got := Parse(in).Title; got != want {
			t.Errorf("%s: title %q, want %q", in, got, want)
		}
	}
}
