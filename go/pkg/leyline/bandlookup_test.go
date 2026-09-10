package leyline

import (
	"strings"
	"testing"
)

func TestResolveBandByAliasAndName(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"2m", "2 m amateur"},
		{"2M", "2 m amateur"},
		{"  70cm  ", "70 cm amateur"},
		{"fm", "FM broadcast"},
		{"noaa", "NOAA weather"},
		{"wx", "NOAA weather"},
		// The full name works too, with or without its spaces.
		{"2 m amateur", "2 m amateur"},
		{"2mamateur", "2 m amateur"},
		{"NOAA weather", "NOAA weather"},
	} {
		b, err := ResolveBand(tc.in)
		if err != nil {
			t.Errorf("ResolveBand(%q): %v", tc.in, err)
			continue
		}
		if b.Name != tc.want {
			t.Errorf("ResolveBand(%q) = %q, want %q", tc.in, b.Name, tc.want)
		}
	}
}

// A band name is not something anyone guesses, so the error has to teach.
func TestResolveBandErrorsTeach(t *testing.T) {
	_, err := ResolveBand("2mm")
	if err == nil {
		t.Fatal("2mm is not a band")
	}
	if got := err.Error(); !strings.Contains(got, "2m") || !strings.Contains(got, "did you mean") {
		t.Errorf("a near miss should suggest: %q", got)
	}
	_, err = ResolveBand("nonsense")
	if err == nil {
		t.Fatal("nonsense is not a band")
	}
	// Nothing close: list what there is rather than leave them guessing.
	for _, want := range []string{"2m", "fm", "noaa", "ley bands"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the fallback error should list %q: %q", want, err.Error())
		}
	}
	if _, err := ResolveBand("   "); err == nil {
		t.Error("an empty name is an error")
	}
}

// Every band needs at least one alias or --band cannot reach it, and no alias
// may be shared by two bands.
func TestBandAliasesAreCompleteAndUnique(t *testing.T) {
	seen := map[string]string{}
	for _, b := range Bands() {
		if len(b.Aliases) == 0 {
			t.Errorf("%q has no alias, so --band cannot reach it", b.Name)
		}
		for _, a := range b.Aliases {
			if a != bandKey(a) {
				t.Errorf("%q: alias %q is not already normalised", b.Name, a)
			}
			if prev, dup := seen[a]; dup {
				t.Errorf("alias %q is on both %q and %q", a, prev, b.Name)
			}
			seen[a] = b.Name
		}
	}
}

// The reason bands are not accepted where a frequency is. If these ever stopped
// parsing as frequencies the positional could take band names, and if a band
// alias were ever added to the frequency path these would silently change
// meaning.
func TestMetreAliasesAlreadyParseAsFrequencies(t *testing.T) {
	for _, tc := range []struct {
		alias string
		hz    uint64
	}{
		{"2m", 2_000_000},
		{"20m", 20_000_000},
		{"160m", 160_000_000},
	} {
		hz, err := ParseUserFrequency(tc.alias)
		if err != nil || hz != tc.hz {
			t.Errorf("ParseUserFrequency(%q) = %v, %v; want %d", tc.alias, hz, err, tc.hz)
		}
		// And the same string is a band alias, which is the collision.
		if _, err := ResolveBand(tc.alias); err != nil {
			t.Errorf("%q should also be a band alias: %v", tc.alias, err)
		}
	}
}

func TestBandWidthAndCentre(t *testing.T) {
	b, err := ResolveBand("noaa")
	if err != nil {
		t.Fatal(err)
	}
	if got := b.WidthHz(); got != 150_000 {
		t.Errorf("NOAA width = %d, want 150000", got)
	}
	if got := b.CenterHz(); got != 162_475_000 {
		t.Errorf("NOAA centre = %d, want 162475000", got)
	}
	// The centre is inside the band, for every band.
	for _, b := range Bands() {
		if c := b.CenterHz(); c < b.MinHz || c > b.MaxHz {
			t.Errorf("%q: centre %d outside %d..%d", b.Name, c, b.MinHz, b.MaxHz)
		}
	}
}
