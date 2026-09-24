// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// A topic is a longer explanation reached with `ley help <topic>`. Topics
// keep the verbs' --help short: a verb says what it does and points here for
// the why. Each topic is a hidden, non-runnable Cobra command whose help
// template prints only the text (no Usage block), so `ley help squelch`,
// `ley squelch` and `ley squelch --help` all print the same thing.
type topic struct {
	name  string
	short string
	// text renders the body; the table-driven topics build theirs at
	// runtime from the leyline package so help and behaviour cannot drift.
	text func() string
}

// topics is in the order `ley --help` lists them.
var topics = []topic{
	{"squelch", "Muting the static between transmissions, and the dBFS scale", topicSquelch},
	{"frequencies", "How to write a frequency (a bare number is MHz)", topicFrequencies},
	{"modes", "NFM, WFM, AM, USB, LSB, CW: which one to use where", topicModes},
	{"gain", "What the gain numbers mean and how to spot overload", topicGain},
	{"presets", "Named frequencies and the bands ley recognises", topicPresets},
	{"glossary", "Capture, channel, dBFS, FFT, sample rate, sink and friends", topicGlossary},
	{"scripting", "--json output, exit codes and how long a channel lives", topicScripting},
	{"roadmap", "Verbs that are planned but not in this build", topicRoadmap},
}

// topicByName finds a topic case-insensitively; nil when there is none.
func topicByName(name string) *topic {
	for i := range topics {
		if strings.EqualFold(topics[i].name, name) {
			return &topics[i]
		}
	}
	return nil
}

// topicList renders the "Help topics" block shown by `ley --help`.
func topicList() string {
	var b strings.Builder
	for _, t := range topics {
		fmt.Fprintf(&b, "  %-12s %s\n", t.name, t.short)
	}
	return strings.TrimRight(b.String(), "\n")
}

// newTopicCommands builds the hidden topic commands, skipping any name a
// verb already owns (`ley presets` prints the table; `ley help presets`
// still prints this topic, since help looks topics up first).
func newTopicCommands(app *App, taken map[string]bool) []*cobra.Command {
	var cmds []*cobra.Command
	for _, t := range topics {
		if taken[t.name] {
			continue
		}
		cmd := &cobra.Command{
			Use:    t.name,
			Short:  t.short,
			Hidden: true,
			Args:   cobra.NoArgs,
		}
		cmd.SetHelpFunc(func(c *cobra.Command, _ []string) {
			app.printHelpText(c, t.text())
		})
		cmds = append(cmds, cmd)
	}
	return cmds
}

// newHelpCommand is the `ley help` verb: a topic name prints the topic, a
// verb name prints that verb's --help, nothing prints the root help.
func newHelpCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:     "help [command or topic]",
		Short:   "Help for a command, or a longer explanation of a topic",
		Long:    "help prints a command's help (the same as 'ley <command> --help')\nor one of the topics below.\n\nTopics:\n" + topicList(),
		Example: "  ley help tune            # the same as ley tune --help\n  ley help squelch         # what squelch is and how to set it\n  ley help presets         # the named frequencies and bands",
		GroupID: GroupLooking,
		Args:    cobra.ArbitraryArgs,
		ValidArgsFunction: func(c *cobra.Command, _ []string, toComplete string) ([]cobra.Completion, cobra.ShellCompDirective) {
			var out []cobra.Completion
			for _, sub := range c.Root().Commands() {
				if sub.IsAvailableCommand() && strings.HasPrefix(sub.Name(), toComplete) {
					out = append(out, cobra.CompletionWithDesc(sub.Name(), sub.Short))
				}
			}
			for _, t := range topics {
				if strings.HasPrefix(t.name, toComplete) {
					out = append(out, cobra.CompletionWithDesc(t.name, t.short))
				}
			}
			return out, cobra.ShellCompDirectiveNoFileComp
		},
		RunE: func(c *cobra.Command, args []string) error {
			if app.JSON {
				return noJSONErrorf("help", "ley help scripting says what --json prints and which verbs print it")
			}
			root := c.Root()
			if len(args) == 0 {
				root.InitDefaultHelpFlag()
				return root.Help()
			}
			if t := topicByName(args[0]); t != nil {
				app.printHelpText(c, t.text())
				return nil
			}
			cmd, rest, err := root.Find(args)
			if err != nil || cmd == nil || cmd == root || len(rest) > 0 {
				return usageErrorf("no command or topic named %q.\n\nTopics:\n%s\n\nRun 'ley --help' for the commands.", strings.Join(args, " "), topicList())
			}
			cmd.InitDefaultHelpFlag()
			return cmd.Help()
		},
	}
}

func topicSquelch() string {
	return `Squelch mutes the audio while the signal is weaker than a level you choose,
so between transmissions you hear silence instead of static.

Levels are dBFS (decibels relative to full scale): 0 is the loudest the
radio can represent and every real signal is below that, so the numbers are
negative. Where an empty channel sits depends on the gain: on an RTL-SDR at
auto gain it reads roughly -30 to -40 dBFS, at low gain -60 to -70 (squelch
auto measures it for you);
a strong local station reaches -30 or better. The level is the strength of
the signal at the antenna, not the loudness in the speakers (that is
volume).

  auto   measure the band's noise floor and mute below floor + 10 dB.
         'ley tune' does this by itself for NFM and AM; 'ley set squelch
         auto' repeats the measurement, e.g. after moving to another band.
  off    never mute. WFM broadcast, SSB and CW default to off: broadcast
         carries a signal all the time, and on SSB the noise is part of
         finding the station.
  -40    a fixed level (also -40dB, -40dBFS). Lower, more negative, lets
         weaker signals and more noise through; higher mutes more.

Reading the meter line 'ley tune' prints:
  146.520 MHz NFM  signal -42 dBFS  muted, waiting for a signal
'signal' is the current level; 'muted' means it is below the squelch level
and 'audio' means you are hearing it. Static between transmissions: raise
the squelch (ley set squelch -50). A station that cuts in and out: lower it
(ley set squelch -70), or give the radio more gain (ley help gain).

  ley tune 146.52              squelch auto; the banner prints the level
  ley set squelch -45          mute below -45 dBFS
  ley set squelch off          hear everything, noise included`
}

func topicFrequencies() string {
	return `Every command that takes a frequency reads it the same way, and prints
the frequency it understood so a slip is easy to spot.

  146.52       a bare number is MHz: 146.520 MHz
  7.040        also MHz: 7.040 MHz (40 m amateur band)
  1010k        k, M and G suffixes mean kHz, MHz and GHz: 1010 kHz
  146.52M      the same as 146.52
  146520000    a number of 100 000 or more is plain Hz
  1.4652e8     scientific notation is Hz
  noaa         'ley tune' also takes a preset name (ley help presets)

Suffixes are case-insensitive (1010K, 146.52m, 146.52 MHz) and may be
spelled out (146.52 mhz, 1010 khz). Commas are not accepted: write 146.52,
not 146,52, and 146520000, not 146,520,000.

Out-of-range errors print the radio's tuning range and, when re-reading
your number as kHz lands inside a band ley knows, the exact form to type
("did you mean 1.010 MHz (AM broadcast)? write 1010k"). An RTL-SDR tunes
roughly 24 MHz to 1.7 GHz; AM broadcast and shortwave below that need an
upconverter, and the error says so instead of guessing.

Printed frequencies always carry a unit and three decimals: 146.520 MHz,
1.010 MHz, 500 Hz. Bands ley recognises (they choose the default mode and
bandwidth) are listed by 'ley help presets'.

  ley tune 146.52              146.520 MHz, 2 m amateur band
  ley tune 1010k               1.010 MHz, AM broadcast (needs an upconverter)
  ley spectrum 101.1           the FM broadcast band around 101.100 MHz
  ley set freq 146.62          move the playing channel`
}

func topicModes() string {
	return `The mode is how the radio turns a signal into sound (demodulation). Pick
the one the station uses: the wrong mode gives garbled or silent audio, not
an error.

  nfm   narrow FM: two-way voice. 2 m and 70 cm amateur, marine VHF, NOAA
        weather, most handheld radios. Bandwidth 12.5 kHz.
  wfm   wide FM: broadcast stations, 87.5 to 108 MHz. Bandwidth 200 kHz.
  am    amplitude modulation: airband (aircraft and towers, 118 to 137 MHz),
        AM broadcast (530 to 1700 kHz), CB. Bandwidth 10 kHz.
  usb   upper sideband: single-sideband voice, the amateur convention at
        and above 10 MHz (20 m, 15 m, 10 m). Bandwidth 2.8 kHz.
  lsb   lower sideband: single-sideband voice below 10 MHz (160 m, 80 m,
        40 m). Bandwidth 2.8 kHz.
  cw    Morse code: a 500 Hz filter and a tone for the carrier.
  raw   no demodulation: raw IQ samples for tools, no audio.

Two names pick by frequency, and ley prints which one it chose:
  fm    WFM when the frequency is inside the FM broadcast band, 87.500 MHz
        to 108.000 MHz inclusive; NFM everywhere else.
  ssb   USB at 10.000 MHz and above; LSB below 10.000 MHz.
  nbfm and narrowfm mean nfm; wbfm, widefm and broadcast mean wfm. Names
  are case-insensitive.

Without --mode, 'ley tune' uses the usual mode of the band (ley help presets
lists the bands with their modes) and NFM when the frequency is in no
known band; it prints one line saying what it chose and why. Scripts should
pass --mode so a change to the band table cannot surprise them.

To see what a mode does rather than hear it, 'ley scope' draws the waveform
the demodulator made: FM voice through the AM detector is a flat line with
ripple, a carrier in CW is a sine, NFM voice is a voice.

  ley tune 101.1 --mode fm     WFM: 101.100 MHz is on the broadcast band
  ley tune 7.040 --mode ssb    LSB: below 10 MHz
  ley tune 121.5               AM without asking: airband
  ley set mode am              switch the playing channel to AM
  ley scope 146.52             draw what the demodulator is making`
}

func topicGain() string {
	return `Gain is how much the radio amplifies what the antenna picks up before it
turns the signal into numbers, in dB. More gain makes weak signals
audible. Too much gain overloads the radio, and then everything gets worse
at once: the noise floor rises, stations appear at frequencies where there
is nothing (images), and a strong station splatters across its neighbours.

The numbers are the radio's own. An RTL-SDR offers about 0 to 49.6 dB in
fixed steps; ley snaps a value to the nearest step and prints the value the
radio applied. 'ley devices' lists each radio's gain elements (stages) with
their ranges.

  auto  let the radio choose. The default, and right for most listening.
  30    a fixed gain in dB (30dB is accepted too). Negative values are
        rejected with the element's range.

Rules of thumb: start with auto. If a distant station is faint and the
noise floor in 'ley spectrum' is low, raise the gain about 5 dB at a time.
If the floor rises as fast as the signal, or ghost stations appear, lower
it. A radio with more than one gain stage (a HackRF has LNA, VGA and an
AMP switch) takes a bare value on its first stage. 'ley set' takes
--element to pick another; tune, record and the other verbs that take
--gain take stage=dB pairs instead, several at once, set in the order
given.

  ley set gain 30              fixed 30 dB, snapped to the radio's step
  ley set gain auto            back to automatic
  ley set gain 20 --element IF one stage of a multi-stage radio
  ley record 462.5625 --gain LNA=0,VGA=0   a HackRF's LNA and VGA at 0 dB`
}

// topicPresets is generated from the preset and band tables so the help
// can never disagree with what tune does.
func topicPresets() string {
	var b strings.Builder
	b.WriteString(`Presets are names 'ley tune' accepts in place of a frequency. Each one is a
fixed frequency and mode; ley does not probe or scan for the best channel
(that is 'ley scan', see ley help roadmap). Names are case-insensitive.

`)
	tw := tabwriter.NewWriter(&b, 0, 0, 2, ' ', 0)
	for _, p := range leyline.Presets() {
		aliases := ""
		if len(p.Aliases) > 0 {
			aliases = "also: " + strings.Join(p.Aliases, ", ")
		}
		// The description repeats the frequency in parentheses; the column
		// already shows it.
		desc := p.Description
		if i := strings.LastIndex(desc, " ("); i > 0 && strings.HasSuffix(desc, ")") {
			desc = desc[:i]
		}
		fmt.Fprintf(tw, "  %s\t%s\t%s\t%s\t%s\n", p.Name, leyline.FormatFrequency(p.Hz), leyline.ModeName(p.Mode), desc, aliases)
	}
	_ = tw.Flush()
	b.WriteString(`
Bands ley recognises. Without --mode, tune uses the band's mode and
bandwidth; outside every band it uses NFM and says "no band recognised".
usb/lsb means the sideband follows the amateur convention: USB at and above
10 MHz, LSB below (ley help modes).

`)
	tw = tabwriter.NewWriter(&b, 0, 0, 2, ' ', 0)
	// The bands, then the groups, as `ley bands` lists them: a group is a name a sweep takes whole.
	for _, band := range append(leyline.Bands(), leyline.BandGroups()...) {
		mode := leyline.ModeName(band.Mode)
		if band.Mode == leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED {
			mode = "usb/lsb"
		}
		fmt.Fprintf(tw, "  %s\t%s to %s\t%s\t%s\t%s\n", band.Name, leyline.FormatFrequency(band.MinHz), leyline.FormatFrequency(band.MaxHz), mode, formatBandwidth(band.BandwidthHz), band.Note)
	}
	_ = tw.Flush()
	b.WriteString(`
  ley tune noaa                noaa is an alias of noaa1, 162.550 MHz
  ley tune calling             146.520 MHz, 2 m simplex calling
  ley tune guard               121.500 MHz, AM`)
	return b.String()
}

// formatBandwidth renders a channel bandwidth as kHz or Hz.
func formatBandwidth(hz uint32) string {
	if hz >= 1000 {
		return strings.TrimSuffix(strings.TrimRight(fmt.Sprintf("%.1f", float64(hz)/1000), "0"), ".") + " kHz"
	}
	return fmt.Sprintf("%d Hz", hz)
}

func topicGlossary() string {
	return `daemon       leylined, the background process that owns the radio and does all
             the radio work. Every ley command talks to it (ley daemon start).
device       a radio the daemon can see: an RTL-SDR, or a file 'ley play'
             attached as a pretend radio. 'ley devices' lists them.
capture      a radio tuned to a band: a centre frequency and a sample rate.
             One capture per radio; several channels can share it, which is
             why a second terminal can listen without 'device busy'.
channel      one station picked out of a capture: an offset from the
             centre, a bandwidth and a mode. 'ley tune' makes one and
             removes it on exit; 'ley set' adjusts it.
sink         where a channel's audio goes: the speakers (an audio sink), a
             file, or a stream to a client.
mode         how a channel turns the signal into sound: nfm, wfm, am, usb,
             lsb, cw (ley help modes).
bandwidth    how wide a slice of spectrum the channel listens to; each mode
             has a usual width (12.5 kHz for NFM, 200 kHz for WFM).
sample rate  how many samples per second the radio delivers, which is also
             how wide a band one capture covers (2.4 MSPS = 2.4 MHz).
dBFS         decibels relative to full scale: 0 is the loudest the radio can
             represent; a quiet channel reads -30 to -70 depending on gain, a
             strong local station -10 or better.
             Signal levels, squelch levels and spectrum bins are all dBFS.
squelch      mute the audio while the signal is weaker than a level
             (ley help squelch).
gain         how much the radio amplifies the antenna signal, in dB
             (ley help gain).
FFT          fast Fourier transform: the daemon's measurement of how loud
             each narrow slice (bin) of the band is. 'ley spectrum' draws
             one such row as a chart; 'ley fft' prints rows as numbers.
spectrum     the picture of a band: frequency left to right, loudness up.
preset       a name for a frequency and mode, e.g. noaa (ley help presets).
id           every object has one: dev_..., cap_..., chan_.... ley also
             accepts an id prefix, a row number from the listing, or a
             frequency wherever an id is expected.`
}

func topicScripting() string {
	return `Machine output: add --json to any command that has data to give.
It prints the proto3 JSON mapping of the leyline.v1 messages
(docs/reference/cli.md): lowerCamelCase keys, 64-bit integers as strings, one
object per line for streams (NDJSON). Anything meant for a person (banners,
"using NFM: ...") goes to stderr, so stdout is always parseable. A verb
whose output is a script, a file or a launchd action ('ley help', 'ley
completion', 'ley daemon install|uninstall|logs') refuses --json with a
usage error and exit 2 rather than ignoring it, so a pipeline stops where
it went wrong.

Documented exceptions to the proto3 rule: bulk rows have no proto message,
so 'ley fft' and 'ley spectrum --json' print
{seq, sample_index, center_hz, span_hz, bins, floor_db} (plus peaks for
spectrum), 'ley waterfall --json' the same with looks, 'ley phosphor --json'
{seq, sample_index, center_hz, span_hz, bins, levels, floor_db, range_db,
counts} with counts the base64 histogram grid, and 'ley listen'
{seq, sample_index, sample_rate, format, pcm} with pcm base64-encoded; fft
and waterfall rows are gap-marked, so a
{"gap":{"from_sample","to_sample"}} line precedes the first row after the
daemon dropped some. 'ley presets --json' and 'ley bands --json' print
arrays of the client-local tables, and 'ley version --json' a client-local
{version, go, os, arch}.

Audio for a tool or an agent: 'ley listen' is 'ley tune' with the samples
on stdout instead of the speakers. It makes a channel when none exists and
removes it on exit, or taps one already running when given a channel id.
--format bin writes the raw PCM frames (mono, little-endian, S16 in this
build; the rate and format are named on stderr).

Exit codes:
  0    ok, including Ctrl-C during a live phase (tune, play, spectrum
       --watch, fft, listen, devices --watch)
  1    the daemon refused or failed; the message keeps the daemon's code in
       brackets, e.g. [DEVICE_BUSY]
  2    usage error: bad flag or argument, unknown verb, setting or preset.
       Nothing was sent to the daemon.
  3    the daemon is not running (from any verb): ley daemon start
  130  interrupted before the live phase began
Error lines read "ley: <what went wrong>. <what to do next>"; a daemon
refusal reads "ley: <message> [CODE]".

Presence: a channel made by ley lives as long as the ley command runs, and
Ctrl-C removes it. --persistent (tune, play) leaves the channel running,
prints the ids of what it made and exits; 'ley state' lists it, 'ley set
--channel <id>' adjusts it, 'ley stop <id>' removes it, and 'ley stop all'
removes every channel on the radio and the capture holding them, so the
radio is free. 'ley devices detach' removes a playback device together
with its channels.

A voice channel squelches by default however the run prints: 'ley tune'
measures the floor under --json and --persistent too and says on stderr
what it chose; '--squelch off' keeps the channel open. 'ley listen' and
'ley play' leave squelch off unless --squelch asks for one.
Pass --mode explicitly rather than relying on band defaults, and give
frequencies with a unit (146.52M) so a bare-number rule change cannot
change the meaning. Ids, prefixes, row numbers and frequencies are all
accepted as selectors; scripts should use full ids.

  ley state --json                          snapshot of everything
  ley tune 146.52M --mode nfm --persistent --json
  ley set squelch -40 --channel chan_01J... --json
  ley fft --freq 101.1M --rate 10 | jq .bins[0]
  ley listen 162.55 --count 10              ten rows of decoded audio
  ley presets --json | jq -r '.[].name'     the client-local tables`
}

// topicRoadmap is generated from the stub table.
func topicRoadmap() string {
	var b strings.Builder
	if len(Stubs) == 0 {
		b.WriteString("Every verb ley knows is in this build. What is planned next lives in\ndocs/plans/build-order.md; the Mac app is the next milestone.\n")
	} else {
		b.WriteString("Planned, not in this build. Running one of these verbs exits 2 with the\nsame line as below.\n\n")
		for _, s := range Stubs {
			fmt.Fprintf(&b, "  %-8s %s (%s)\n           today: %s\n", s.use, s.short, s.milestone, s.today)
		}
	}
	b.WriteString("\nRecording is in this build:\n\n")
	b.WriteString("  ley record <freq>        write what the radio hears to a file\n")
	b.WriteString("  ley recordings           what has been recorded\n")
	b.WriteString("  ley recordings path <id> where a recording is, for Finder or another tool\n")
	b.WriteString("\nDecoding is in this build:\n\n")
	b.WriteString("  ley decoders             the installed decoder plugins\n")
	b.WriteString("  ley decode <name>        run one and print what it hears\n")
	b.WriteString("  ley records              search what kept jobs wrote\n")
	b.WriteString("  ley track <protocol>     the live entity table\n")
	b.WriteString("  ley watch <name> ...     filter records, and notify on a match\n")
	b.WriteString("\nStill to come there: 'ley label' and 'ley devices-seen', and 'ley\nidentify'.\n")
	b.WriteString("\nThe daemon-side relative squelch (mute at 'noise floor + N dB' measured by\nthe daemon rather than by ley) is the recorded follow-up to auto squelch.")
	return b.String()
}
