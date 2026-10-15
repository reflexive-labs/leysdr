// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"io"
	"math"
	"os"
	"path/filepath"
	"testing"

	"google.golang.org/protobuf/encoding/protodelim"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/plugin"
)

// TestManifestMatchesTheFile keeps the manifest this binary prints identical to
// decoders/speech/manifest.json, which is what the daemon's registry reads.
func TestManifestMatchesTheFile(t *testing.T) {
	data, err := os.ReadFile("../../../decoders/speech/manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	var fromFile leylinev1.DecoderManifest
	if err := protojson.Unmarshal(data, &fromFile); err != nil {
		t.Fatalf("decoders/speech/manifest.json does not parse: %v", err)
	}
	if !proto.Equal(&fromFile, manifest()) {
		t.Errorf("the built manifest and decoders/speech/manifest.json differ:\nfile:  %v\nbuilt: %v", &fromFile, manifest())
	}
	// The plugin reads segments and so must say so, or the daemon would stream it continuous audio.
	if fromFile.GetInput().GetMode() != leylinev1.InputMode_SEGMENTED {
		t.Errorf("input mode is %v, want SEGMENTED", fromFile.GetInput().GetMode())
	}
}

func TestAnUnknownEngineIsRefused(t *testing.T) {
	var stderr bytes.Buffer
	_, err := parseArgs([]string{"--engine", "whisper"}, func(string) string { return "" }, &stderr)
	if err == nil || err.Error() != "no engine whisper; the engines are: openai, scripted" {
		t.Errorf("err = %v", err)
	}
	if opts, err := parseArgs([]string{"--manifest", "--engine", "whisper"}, func(string) string { return "" }, &stderr); err != nil || !opts.printManifest {
		t.Errorf("--manifest should print the manifest whatever the engine: %v, %v", opts, err)
	}
}

// The rates segmentStream writes at: the daemon's audio rate and a capture's.
const testAudioRate, testCaptureRate = 48000, 2_400_000

// segmentStream is what the daemon writes a speech plugin: the key when cred is set, the
// descriptor, then each segment as a START frame holding all its audio, a constant 0.1, and an
// END frame.
func segmentStream(t *testing.T, cred *leylinev1.SetCredentialRequest, lengths ...int) []byte {
	t.Helper()
	var in bytes.Buffer
	write := func(m proto.Message) {
		if _, err := protodelim.MarshalTo(&in, m); err != nil {
			t.Fatal(err)
		}
	}
	if cred != nil {
		write(cred)
	}
	write(&leylinev1.StreamDescriptor{
		StreamId: "str_test", Kind: leylinev1.StreamKind_AUDIO,
		Params: &leylinev1.StreamDescriptor_Audio{Audio: &leylinev1.AudioParams{SampleRate: testAudioRate, Format: leylinev1.AudioSampleFormat_F32}},
		SpanHz: testCaptureRate,
	})
	at := uint64(1_000_000)
	for i, n := range lengths {
		payload := make([]byte, 0, 4*n)
		for range n {
			payload = binary.LittleEndian.AppendUint32(payload, math.Float32bits(0.1))
		}
		tm := &leylinev1.SampleTime{CaptureId: "cap_test", SampleIndex: at}
		write(&leylinev1.Frame{Seq: uint64(2 * i), Time: tm, Segment: leylinev1.SegmentMark_SEGMENT_START, Payload: payload})
		end := at + uint64(n*testCaptureRate/testAudioRate)
		write(&leylinev1.Frame{Seq: uint64(2*i + 1), Time: &leylinev1.SampleTime{CaptureId: "cap_test", SampleIndex: end}, Segment: leylinev1.SegmentMark_SEGMENT_END})
		at = end + testCaptureRate
	}
	return in.Bytes()
}

// readRecords is every delimited record in a plugin's stdout.
func readRecords(out []byte) []*leylinev1.DecodeRecord {
	var recs []*leylinev1.DecodeRecord
	r := bufio.NewReader(bytes.NewReader(out))
	for {
		var rec leylinev1.DecodeRecord
		if err := protodelim.UnmarshalFrom(r, &rec); err != nil {
			return recs
		}
		recs = append(recs, &rec)
	}
}

// runPlugin runs the plugin over segments of the given lengths, the way the daemon does, with no
// key, and returns the records.
func runPlugin(t *testing.T, args []string, env map[string]string, lengths ...int) []*leylinev1.DecodeRecord {
	t.Helper()
	opts, err := parseArgs(args, func(k string) string { return env[k] }, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	err = plugin.RunSegmentedStreams(t.Context(), bytes.NewReader(segmentStream(t, nil, lengths...)), &out, "",
		func(rate uint32, cred *leylinev1.SetCredentialRequest) plugin.SegmentDecoder {
			eng, err := newEngine(opts.engine, opts.config, cred)
			if err != nil {
				t.Fatal(err)
			}
			return newDecoder(eng, float64(rate), io.Discard, func(code int) { t.Errorf("the plugin exited %d", code) })
		})
	if err != nil {
		t.Fatal(err)
	}
	return readRecords(out.Bytes())
}

// The scripted engine gives one record per segment from the script's lines in order, repeating
// the last when they run out, with the fields, raw bytes and usage a speech record carries.
func TestScriptedRecords(t *testing.T) {
	script := filepath.Join(t.TempDir(), "script.txt")
	if err := os.WriteFile(script, []byte("this is whiskey six alpha bravo charlie\nroger, see you at six alpha\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	recs := runPlugin(t, []string{"--engine", "scripted"}, map[string]string{scriptEnv: script}, 48000, 24000, 4800)
	if len(recs) != 3 {
		t.Fatalf("got %d records, want 3", len(recs))
	}
	wantText := []string{"this is whiskey six alpha bravo charlie", "roger, see you at six alpha", "roger, see you at six alpha"}
	wantCalls := []string{"W6ABC", "", ""}
	wantSeconds := []float64{1, 0.5, 0.1}
	for i, rec := range recs {
		f := rec.GetFields()
		if rec.GetProtocol() != "speech" || f["text"].GetText() != wantText[i] || f["callsigns"].GetText() != wantCalls[i] {
			t.Errorf("record %d: protocol %q text %q callsigns %q", i+1, rec.GetProtocol(), f["text"].GetText(), f["callsigns"].GetText())
		}
		if f["model"].GetText() != "scripted" || f["language"].GetText() != "en" || f["confidence"].GetNumber() != 1 {
			t.Errorf("record %d: model %q language %q confidence %v", i+1, f["model"].GetText(), f["language"].GetText(), f["confidence"])
		}
		if string(rec.GetRaw()) != wantText[i] {
			t.Errorf("record %d: raw %q", i+1, rec.GetRaw())
		}
		u := rec.GetUsage()
		if u.GetProvider() != "scripted" || u.GetModel() != "scripted" || u.GetRequests() != 1 || math.Abs(u.GetAudioSeconds()-wantSeconds[i]) > 1e-9 {
			t.Errorf("record %d: usage %v, want %v s", i+1, u, wantSeconds[i])
		}
		if u.GetFeature() != "" || u.GetJobId() != "" || rec.GetClipUri() != "" || rec.GetOver() != 0 {
			t.Errorf("record %d: the plugin set a field the daemon stamps: %v", i+1, rec)
		}
	}
	if recs[0].GetTime().GetSampleIndex() != 1_000_000 || recs[0].GetTime().GetCaptureId() != "cap_test" {
		t.Errorf("the record is not at its START frame's time: %v", recs[0].GetTime())
	}
}

// With no script the engine says which segment it was, and --model and --language are what the
// record carries.
func TestScriptedWithoutAScript(t *testing.T) {
	recs := runPlugin(t, []string{"--model", "tiny", "--language", "de"}, map[string]string{scriptEnv: "/nonexistent/script.txt"}, 480, 480)
	if len(recs) != 2 {
		t.Fatalf("got %d records, want 2", len(recs))
	}
	for i, rec := range recs {
		f := rec.GetFields()
		if want := "segment " + string(rune('1'+i)); f["text"].GetText() != want {
			t.Errorf("record %d text %q, want %q", i+1, f["text"].GetText(), want)
		}
		if f["model"].GetText() != "tiny" || rec.GetUsage().GetModel() != "tiny" || f["language"].GetText() != "de" {
			t.Errorf("record %d: model %q/%q language %q", i+1, f["model"].GetText(), rec.GetUsage().GetModel(), f["language"].GetText())
		}
	}
}
