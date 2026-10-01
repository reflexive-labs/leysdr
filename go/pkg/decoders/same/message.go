// SPDX-License-Identifier: Apache-2.0

package same

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Protocol is the manifest name this decoder fills into DecodeRecord.protocol.
const Protocol = "same"

// Location is one SAME location code, the six-digit PSSCCC: P names the part of
// the county (0 the whole county), and SSCCC is the five-digit FIPS state and
// county a predicate like `--county 06009` matches.
type Location struct {
	Raw  string // the full six-digit PSSCCC
	Part string // P, the leading digit
	FIPS string // SSCCC, the last five digits
}

// Message is a parsed SAME header.
type Message struct {
	Org       string // originator: EAS, WXR, CIV, PEP
	Event     string // the three-letter event code, EEE
	EventName string // a human name for the event, or the raw code if unknown
	Locations []Location
	Purge     string // TTTT, the valid duration as HHMM
	Issued    string // JJJHHMM, day-of-year and UTC time of issue
	Callsign  string // LLLLLLLL, the sender's id
	Header    string // the header as decoded, one copy
	Start     time.Time
	End       time.Time
}

// FIPSList joins the five-digit FIPS codes with commas, the form a CONTAINS
// predicate splits on to match a single county.
func (m *Message) FIPSList() string {
	out := make([]string, len(m.Locations))
	for i, l := range m.Locations {
		out[i] = l.FIPS
	}
	return strings.Join(out, ",")
}

// RawList joins the full six-digit PSSCCC codes with commas.
func (m *Message) RawList() string {
	out := make([]string, len(m.Locations))
	for i, l := range m.Locations {
		out[i] = l.Raw
	}
	return strings.Join(out, ",")
}

// Parse turns a decoded header ("ZCZC-ORG-EEE-...-CALLSIGN-", with or without
// the trailing dash) into a Message. The issue time carries no year, so it is
// resolved against the current UTC year, and the validity window is the issue
// time plus the purge duration.
func Parse(header string) (*Message, error) {
	return parseAt(header, time.Now().UTC())
}

func parseAt(header string, now time.Time) (*Message, error) {
	h := strings.TrimSuffix(strings.TrimSpace(header), "-")
	if !strings.HasPrefix(h, "ZCZC-") {
		return nil, errors.New("same: header does not start with ZCZC-")
	}
	plus := strings.IndexByte(h, '+')
	if plus < 0 {
		return nil, errors.New("same: header has no + before the purge time")
	}
	left := strings.Split(h[:plus], "-") // ZCZC, ORG, EEE, loc, loc, ...
	if len(left) < 4 {
		return nil, fmt.Errorf("same: header has %d fields before +, want at least 4", len(left))
	}
	right := strings.SplitN(h[plus+1:], "-", 3) // TTTT, JJJHHMM, CALLSIGN
	if len(right) != 3 {
		return nil, fmt.Errorf("same: header has %d fields after +, want 3", len(right))
	}
	m := &Message{
		Org:      left[1],
		Event:    left[2],
		Purge:    right[0],
		Issued:   right[1],
		Callsign: right[2],
		Header:   header,
	}
	m.EventName = EventName(m.Event)
	for _, code := range left[3:] {
		loc, err := parseLocation(code)
		if err != nil {
			return nil, err
		}
		m.Locations = append(m.Locations, loc)
	}
	if len(m.Locations) == 0 {
		return nil, errors.New("same: header carries no location codes")
	}
	start, end, err := window(m.Issued, m.Purge, now)
	if err != nil {
		return nil, err
	}
	m.Start, m.End = start, end
	return m, nil
}

func parseLocation(code string) (Location, error) {
	if len(code) != 6 || !allDigits(code) {
		return Location{}, fmt.Errorf("same: location code %q is not six digits", code)
	}
	return Location{Raw: code, Part: code[:1], FIPS: code[1:]}, nil
}

// window builds the validity window. issued is JJJHHMM (day-of-year and UTC
// time); purge is TTTT (HHMM as a duration). SAME carries no year, so the year
// is now's.
func window(issued, purge string, now time.Time) (time.Time, time.Time, error) {
	if len(issued) != 7 || !allDigits(issued) {
		return time.Time{}, time.Time{}, fmt.Errorf("same: issue time %q is not JJJHHMM", issued)
	}
	if len(purge) != 4 || !allDigits(purge) {
		return time.Time{}, time.Time{}, fmt.Errorf("same: purge time %q is not HHMM", purge)
	}
	jjj, _ := strconv.Atoi(issued[:3])
	ih, _ := strconv.Atoi(issued[3:5])
	im, _ := strconv.Atoi(issued[5:7])
	// Day 001 is 1 January, so add jjj-1 days to the year's first instant.
	start := time.Date(now.Year(), 1, 1, 0, 0, 0, 0, time.UTC).
		AddDate(0, 0, jjj-1).Add(time.Duration(ih)*time.Hour + time.Duration(im)*time.Minute)
	ph, _ := strconv.Atoi(purge[:2])
	pm, _ := strconv.Atoi(purge[2:])
	end := start.Add(time.Duration(ph)*time.Hour + time.Duration(pm)*time.Minute)
	return start, end, nil
}

func allDigits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return len(s) > 0
}
