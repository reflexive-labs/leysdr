// SPDX-License-Identifier: Apache-2.0

package aprs_test

import (
	"math"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/decoders/aprs"
	"github.com/dpup/leysdr/go/pkg/decoders/ax25"
)

// parse builds a UI frame around an information field and parses it, which is
// how every case here states its input: the spec's example text, on the air.
func parse(t *testing.T, dest, source, info string) *leylinev1.DecodeRecord {
	t.Helper()
	raw := ax25.BuildUI(ax25.Address{Call: dest}, addr(source),
		[]ax25.Address{{Call: "WIDE1", SSID: 1, Repeated: true}}, 0xF0, []byte(info))
	f, err := ax25.Parse(raw)
	if err != nil {
		t.Fatalf("frame: %v", err)
	}
	rec := aprs.Parse(f)
	if rec == nil {
		t.Fatal("parse returned no record")
	}
	return rec
}

func addr(s string) ax25.Address {
	for i := 0; i < len(s); i++ {
		if s[i] == '-' {
			ssid := 0
			for j := i + 1; j < len(s); j++ {
				ssid = ssid*10 + int(s[j]-'0')
			}
			return ax25.Address{Call: s[:i], SSID: ssid}
		}
	}
	return ax25.Address{Call: s}
}

func str(t *testing.T, rec *leylinev1.DecodeRecord, name string) string {
	t.Helper()
	v, ok := rec.Fields[name]
	if !ok {
		t.Fatalf("field %q is missing; record has %v", name, keys(rec))
	}
	return v.GetText()
}

func num(t *testing.T, rec *leylinev1.DecodeRecord, name string) float64 {
	t.Helper()
	v, ok := rec.Fields[name]
	if !ok {
		t.Fatalf("field %q is missing; record has %v", name, keys(rec))
	}
	return v.GetNumber()
}

func keys(rec *leylinev1.DecodeRecord) []string {
	out := make([]string, 0, len(rec.Fields))
	for k := range rec.Fields {
		out = append(out, k)
	}
	return out
}

func near(t *testing.T, got, want, tol float64, what string) {
	t.Helper()
	if math.Abs(got-want) > tol {
		t.Errorf("%s = %g, want %g (within %g)", what, got, want, tol)
	}
}

// The uncompressed position examples are from the APRS 1.01 spec, chapter 8:
// 49 degrees 3.50 minutes north, 72 degrees 1.75 minutes west.
const (
	specLat = 49 + 3.50/60
	specLon = -(72 + 1.75/60)
)

func TestUncompressedPosition(t *testing.T) {
	cases := []struct {
		name, info, kind, symbol, comment string
	}{
		{"no timestamp, no messaging", "!4903.50N/07201.75W-Test 001234", "position", "/-", "Test 001234"},
		{"no timestamp, messaging", "=4903.50N/07201.75W-Test 001234", "position", "/-", "Test 001234"},
		{"zulu timestamp", "/092345z4903.50N/07201.75W>Test1234", "position", "/>", "Test1234"},
		{"local timestamp", "@092345/4903.50N/07201.75W>Test1234", "position", "/>", "Test1234"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rec := parse(t, "APRS", "N0CALL-9", c.info)
			if rec.Kind != c.kind {
				t.Errorf("kind = %q, want %q", rec.Kind, c.kind)
			}
			if rec.DeviceId != "N0CALL-9" {
				t.Errorf("device_id = %q, want N0CALL-9", rec.DeviceId)
			}
			if rec.Position == nil {
				t.Fatal("no position")
			}
			near(t, rec.Position.Latitude, specLat, 1e-6, "latitude")
			near(t, rec.Position.Longitude, specLon, 1e-6, "longitude")
			if got := str(t, rec, "symbol"); got != c.symbol {
				t.Errorf("symbol = %q, want %q", got, c.symbol)
			}
			if got := str(t, rec, "comment"); got != c.comment {
				t.Errorf("comment = %q, want %q", got, c.comment)
			}
			if got := str(t, rec, "path"); got != "WIDE1-1*" {
				t.Errorf("path = %q, want WIDE1-1*", got)
			}
			if got := str(t, rec, "destination"); got != "APRS" {
				t.Errorf("destination = %q, want APRS", got)
			}
		})
	}
}

func TestPositionWithCourseSpeedAndAltitude(t *testing.T) {
	rec := parse(t, "APRS", "N0CALL-9", "!4903.50N/07201.75W>088/036/A=001234Going home")
	near(t, num(t, rec, "course_deg"), 88, 1e-9, "course_deg")
	near(t, num(t, rec, "speed_kmh"), 36*1.852, 1e-6, "speed_kmh")
	if rec.Position.AltitudeM == nil {
		t.Fatal("no altitude")
	}
	near(t, *rec.Position.AltitudeM, 1234*0.3048, 1e-6, "altitude_m")
	if got := str(t, rec, "comment"); got != "Going home" {
		t.Errorf("comment = %q, want %q", got, "Going home")
	}
}

// The compressed example is the spec's own: !/5L!!<*e7> sT decodes to 49.5
// north, 72.75 west with no course or speed.
func TestCompressedPosition(t *testing.T) {
	rec := parse(t, "APRS", "N0CALL-9", "!/5L!!<*e7> sT")
	if rec.Position == nil {
		t.Fatal("no position")
	}
	near(t, rec.Position.Latitude, 49.5, 1e-4, "latitude")
	near(t, rec.Position.Longitude, -72.75, 1e-4, "longitude")
	if got := str(t, rec, "symbol"); got != "/>" {
		t.Errorf("symbol = %q, want %q", got, "/>")
	}
}

func TestCompressedPositionWithCourseAndSpeed(t *testing.T) {
	// Course and speed characters 7P: course = (55-33)*4 = 88 degrees,
	// speed = 1.08^(80-33) - 1 = 36.2 knots.
	rec := parse(t, "APRS", "N0CALL-9", "!/5L!!<*e7>7P[")
	near(t, num(t, rec, "course_deg"), 88, 1e-9, "course_deg")
	near(t, num(t, rec, "speed_kmh"), (math.Pow(1.08, 47)-1)*1.852, 1e-3, "speed_kmh")
}

// TestMicE uses the spec's worked example position -- 33 degrees 25.64
// minutes north, 112 degrees 7.35 minutes west, course 251, speed 20 knots --
// with the bytes built from the spec's own encoding tables. Two of them are
// control characters, which is why Mic-E lives in the AX.25 information field
// where any byte is legal and not in a text protocol.
func TestMicE(t *testing.T) {
	rec := parse(t, "SS2UVT", "N0CALL-7", "`(_?\x1e\x1eOj/")
	if rec.Kind != "position" {
		t.Errorf("kind = %q, want position", rec.Kind)
	}
	if rec.Position == nil {
		t.Fatal("no position")
	}
	near(t, rec.Position.Latitude, 33+25.64/60, 1e-6, "latitude")
	near(t, rec.Position.Longitude, -(112 + 7.35/60), 1e-6, "longitude")
	near(t, num(t, rec, "course_deg"), 251, 1e-9, "course_deg")
	near(t, num(t, rec, "speed_kmh"), 20*1.852, 1e-6, "speed_kmh")
	if got := str(t, rec, "symbol"); got != "/j" {
		t.Errorf("symbol = %q, want /j", got)
	}
	if got := str(t, rec, "mic_e_message"); got != "en route" {
		t.Errorf("mic_e_message = %q, want en route", got)
	}
}

// TestMicESouthEast checks the three sign bits the destination address carries,
// which are the part of Mic-E that a decoder gets wrong silently.
func TestMicESouthEast(t *testing.T) {
	rec := parse(t, "332546", "VK2ABC-9", "`(_?\x1e\x1eOj/")
	if rec.Position.Latitude >= 0 {
		t.Errorf("latitude = %g, want southern", rec.Position.Latitude)
	}
	if rec.Position.Longitude <= 0 {
		t.Errorf("longitude = %g, want eastern", rec.Position.Longitude)
	}
	near(t, rec.Position.Longitude, 12+7.35/60, 1e-6, "longitude")
}

// The weather examples are the spec's, chapter 12.
func TestPositionlessWeather(t *testing.T) {
	rec := parse(t, "APRS", "N0CALL", "_10090556c220s004g005t077r000p000P000h50b09900wRSW")
	if rec.Kind != "weather" {
		t.Errorf("kind = %q, want weather", rec.Kind)
	}
	if rec.Position != nil {
		t.Error("a positionless weather report carries no position")
	}
	near(t, num(t, rec, "wind_dir_deg"), 220, 1e-9, "wind_dir_deg")
	near(t, num(t, rec, "wind_kmh"), 4*1.609344, 1e-6, "wind_kmh")
	near(t, num(t, rec, "gust_kmh"), 5*1.609344, 1e-6, "gust_kmh")
	near(t, num(t, rec, "temp_c"), 25, 1e-6, "temp_c")
	near(t, num(t, rec, "rain_mm_1h"), 0, 1e-9, "rain_mm_1h")
	near(t, num(t, rec, "humidity_pct"), 50, 1e-9, "humidity_pct")
	near(t, num(t, rec, "pressure_hpa"), 990, 1e-9, "pressure_hpa")
	if got := str(t, rec, "comment"); got != "wRSW" {
		t.Errorf("comment = %q, want wRSW", got)
	}
}

func TestWeatherInAPositionReport(t *testing.T) {
	rec := parse(t, "APRS", "N0CALL", "!4903.50N/07201.75W_220/004g005t077r000p000P000h50b09900wRSW")
	if rec.Kind != "weather" {
		t.Errorf("kind = %q, want weather", rec.Kind)
	}
	if rec.Position == nil {
		t.Fatal("no position")
	}
	near(t, rec.Position.Latitude, specLat, 1e-6, "latitude")
	near(t, num(t, rec, "wind_dir_deg"), 220, 1e-9, "wind_dir_deg")
	near(t, num(t, rec, "wind_kmh"), 4*1.609344, 1e-6, "wind_kmh")
	near(t, num(t, rec, "temp_c"), 25, 1e-6, "temp_c")
	if _, ok := rec.Fields["course_deg"]; ok {
		t.Error("the wind is not a course; a _ symbol says the numbers are weather")
	}
}

func TestTelemetry(t *testing.T) {
	rec := parse(t, "APRS", "N0CALL", "T#005,199,000,255,073,123,01101001")
	if rec.Kind != "telemetry" {
		t.Errorf("kind = %q, want telemetry", rec.Kind)
	}
	if got := str(t, rec, "seq"); got != "005" {
		t.Errorf("seq = %q, want 005", got)
	}
	for name, want := range map[string]float64{"a1": 199, "a2": 0, "a3": 255, "a4": 73, "a5": 123} {
		near(t, num(t, rec, name), want, 1e-9, name)
	}
	if got := str(t, rec, "digital"); got != "01101001" {
		t.Errorf("digital = %q, want 01101001", got)
	}
}

func TestMessageAckAndReject(t *testing.T) {
	rec := parse(t, "APRS", "N0CALL", ":N0TEST   :Testing{003")
	if rec.Kind != "message" {
		t.Errorf("kind = %q, want message", rec.Kind)
	}
	if got := str(t, rec, "addressee"); got != "N0TEST" {
		t.Errorf("addressee = %q, want N0TEST", got)
	}
	if got := str(t, rec, "text"); got != "Testing" {
		t.Errorf("text = %q, want Testing", got)
	}
	if got := str(t, rec, "msg_id"); got != "003" {
		t.Errorf("msg_id = %q, want 003", got)
	}

	ack := parse(t, "APRS", "N0TEST", ":N0CALL   :ack003")
	if ack.Kind != "ack" || str(t, ack, "msg_id") != "003" {
		t.Errorf("ack: kind %q id %q", ack.Kind, str(t, ack, "msg_id"))
	}
	rej := parse(t, "APRS", "N0TEST", ":N0CALL   :rej003")
	if rej.Kind != "reject" || str(t, rej, "msg_id") != "003" {
		t.Errorf("reject: kind %q id %q", rej.Kind, str(t, rej, "msg_id"))
	}
}

func TestStatus(t *testing.T) {
	rec := parse(t, "APRS", "N0CALL", ">092345zNet control on 146.52")
	if rec.Kind != "status" {
		t.Errorf("kind = %q, want status", rec.Kind)
	}
	if got := str(t, rec, "comment"); got != "Net control on 146.52" {
		t.Errorf("comment = %q", got)
	}
}

func TestObjectAndItem(t *testing.T) {
	obj := parse(t, "APRS", "N0CALL", ";LEYFIELD *092345z4903.50N/07201.75W-Field day")
	if obj.Kind != "object" {
		t.Errorf("kind = %q, want object", obj.Kind)
	}
	if got := str(t, obj, "object_name"); got != "LEYFIELD" {
		t.Errorf("object_name = %q, want LEYFIELD", got)
	}
	if !obj.Fields["alive"].GetFlag() {
		t.Error("a star says the object is live")
	}
	near(t, obj.Position.Latitude, specLat, 1e-6, "latitude")

	killed := parse(t, "APRS", "N0CALL", ";LEYFIELD _092345z4903.50N/07201.75W-")
	if killed.Fields["alive"].GetFlag() {
		t.Error("an underscore says the object has been killed")
	}

	item := parse(t, "APRS", "N0CALL", ")AID!4903.50N/07201.75W-First aid")
	if item.Kind != "item" {
		t.Errorf("kind = %q, want item", item.Kind)
	}
	if got := str(t, item, "object_name"); got != "AID" {
		t.Errorf("object_name = %q, want AID", got)
	}
	near(t, item.Position.Longitude, specLon, 1e-6, "longitude")
}

func TestUnknownFormIsKeptVerbatim(t *testing.T) {
	rec := parse(t, "APRS", "N0CALL", "<IGATE,MSG_CNT=0,LOC_CNT=0")
	if rec.Kind != "other" {
		t.Errorf("kind = %q, want other", rec.Kind)
	}
	if got := str(t, rec, "comment"); got != "<IGATE,MSG_CNT=0,LOC_CNT=0" {
		t.Errorf("comment = %q, want the text unchanged", got)
	}
}

func TestNonAPRSFrameIsSkipped(t *testing.T) {
	raw := ax25.BuildUI(ax25.Address{Call: "TEST"}, ax25.Address{Call: "N0CALL"}, nil, 0xCF, []byte("netrom"))
	f, err := ax25.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if rec := aprs.Parse(f); rec != nil {
		t.Errorf("a PID of 0xcf is not APRS, got %v", rec)
	}
}
