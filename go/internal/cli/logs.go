package cli

import (
	"bytes"
	"errors"
	"io"
	"strings"

	"github.com/dpup/leysdr/go/internal/ui"
)

// The daemon writes swift-log's stream format:
//
//	2026-09-09T04:12:54+0000 info leyline.daemon: [LeylineDaemon] listening on ...
//
// On a terminal `ley daemon logs` re-lays that into columns (the clock, the
// level, one subsystem token, then the message) so the level -- the thing a
// reader scans for -- has an anchor. Piped, the log is passed through
// byte-for-byte, and any line that does not parse is passed through here too:
// ley must never eat a line it did not understand.
type logLine struct {
	date, clock, level, label, subsys, msg string
}

// logLevels are the swift-log levels, in the spelling the handler writes.
var logLevels = map[string]bool{
	"trace": true, "debug": true, "info": true, "notice": true,
	"warning": true, "error": true, "critical": true,
}

// parseLogLine splits one log line; ok is false for anything that is not
// shaped like "<timestamp> <level> [<label>:] [[<source>]] <message>".
func parseLogLine(s string) (logLine, bool) {
	rest := strings.TrimLeft(s, " \t")
	ts, rest, ok := strings.Cut(rest, " ")
	if !ok {
		return logLine{}, false
	}
	date, clock, ok := splitTimestamp(ts)
	if !ok {
		// "2026-09-09 04:12:54+0000": the date and clock as two tokens.
		var clockTok string
		if clockTok, rest, ok = strings.Cut(rest, " "); !ok {
			return logLine{}, false
		}
		if date, clock, ok = splitTimestamp(ts + "T" + clockTok); !ok {
			return logLine{}, false
		}
	}
	level, rest, ok := strings.Cut(strings.TrimLeft(rest, " "), " ")
	if !ok || !logLevels[strings.ToLower(level)] {
		return logLine{}, false
	}
	l := logLine{date: date, clock: clock, level: strings.ToLower(level)}
	rest = strings.TrimLeft(rest, " ")
	// The label ("leyline.daemon:", or "leyline.daemon :") names the
	// subsystem; only its last segment earns a column.
	if tok, after, cut := strings.Cut(rest, " "); cut {
		switch {
		case strings.HasSuffix(tok, ":") && isLogLabel(strings.TrimSuffix(tok, ":")):
			l.label, rest = strings.TrimSuffix(tok, ":"), after
		case isLogLabel(tok) && strings.HasPrefix(after, ":"):
			l.label, rest = tok, strings.TrimPrefix(after, ":")
		}
		l.subsys = lastSegment(l.label)
		rest = strings.TrimLeft(rest, " ")
	}
	// swift-log's "[source]" is the module the line came from, which in this
	// daemon repeats the label ("LeylineDaemon" beside "leyline.capture").
	// Drop it only when it does, so a source that says something new lives.
	if strings.HasPrefix(rest, "[") {
		if i := strings.Index(rest, "]"); i > 0 && repeatsLabel(rest[1:i], l.label) {
			rest = strings.TrimLeft(rest[i+1:], " ")
		}
	}
	l.msg = rest
	return l, true
}

// Column widths of the re-laid line. The clock is fixed at 8; the level and
// the subsystem are padded so the message always starts at the same column.
const (
	logLevelCol  = 8
	logSubsysCol = 8
	// logWideMin is the width below which the subsystem column is dropped:
	// on a narrow terminal the message matters more than its source.
	logWideMin = 60
)

// logRelay renders the daemon's log for a terminal, one line at a time. It
// remembers the date it last printed so a run of lines from the same day
// carries a clock and not a repeated date.
type logRelay struct {
	st   ui.Style
	w    io.Writer
	date string
	pend []byte
}

// line renders one raw log line (no trailing newline) as the text to print.
// A line that does not parse comes back verbatim.
func (r *logRelay) line(raw string) string {
	l, ok := parseLogLine(raw)
	if !ok {
		return raw
	}
	var b strings.Builder
	if l.date != r.date {
		r.date = l.date
		b.WriteString(r.st.Muted(l.date) + "\n")
	}
	b.WriteString(r.st.Muted(l.clock))
	b.WriteString("  " + r.st.Pad(levelInk(r.st, l.level), logLevelCol))
	if r.wide() {
		sub := r.st.Truncate(l.subsys, logSubsysCol)
		b.WriteString("  " + r.st.Pad(r.st.Muted(sub), logSubsysCol))
	}
	return strings.TrimRight(b.String()+"  "+l.msg, " ")
}

// wide reports whether there is room for the subsystem column; an unknown
// width is treated as wide enough (the default is 80).
func (r *logRelay) wide() bool { return r.st.Width == 0 || r.st.Width >= logWideMin }

// levelInk colours a level word by what it means: red for a failure, yellow
// for a warning, dim for the chatter, plain for the ordinary line.
func levelInk(st ui.Style, level string) string {
	switch level {
	case "error", "critical":
		return st.Err(level)
	case "warning", "notice":
		return st.Warn(level)
	case "debug", "trace":
		return st.Muted(level)
	default:
		return level
	}
}

// followLine marks where the log stood when -f began, so the lines that
// arrive next are visibly new. It is a line of text, not a colour: the
// distinction survives with the ink off.
func (r *logRelay) followLine(path string) string {
	text := "following " + path + "; Ctrl-C stops "
	if w := r.st.Width; w > 0 {
		if n := w - ui.Visible(text); n > 0 {
			text += r.st.Rule(n)
		}
		text = r.st.Truncate(text, w)
	}
	return r.st.Muted(strings.TrimRight(text, " "))
}

// copy reads everything available from src and writes the re-laid lines. A
// line the daemon has not finished writing is held back until its newline
// arrives, so -f never splits a line down the middle.
func (r *logRelay) copy(src io.Reader) error {
	buf := make([]byte, 32*1024)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			r.pend = append(r.pend, buf[:n]...)
			for {
				i := bytes.IndexByte(r.pend, '\n')
				if i < 0 {
					break
				}
				line := string(r.pend[:i])
				r.pend = r.pend[i+1:]
				if _, werr := io.WriteString(r.w, r.line(strings.TrimSuffix(line, "\r"))+"\n"); werr != nil {
					return werr
				}
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
	}
}

// splitTimestamp reads "2026-09-09T04:12:54+0000" into its date and clock.
func splitTimestamp(s string) (date, clock string, ok bool) {
	if len(s) < 19 || s[4] != '-' || s[7] != '-' || (s[10] != 'T' && s[10] != ' ') || s[13] != ':' || s[16] != ':' {
		return "", "", false
	}
	for i, r := range s[:19] {
		if i == 4 || i == 7 || i == 10 || i == 13 || i == 16 {
			continue
		}
		if r < '0' || r > '9' {
			return "", "", false
		}
	}
	return s[:10], s[11:19], true
}

// isLogLabel reports whether s is a dotted identifier such as leyline.daemon.
func isLogLabel(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case r == '.' || r == '_' || r == '-':
		default:
			return false
		}
	}
	return true
}

// lastSegment is the part of a dotted label that names the subsystem.
func lastSegment(s string) string {
	if i := strings.LastIndex(s, "."); i >= 0 && i+1 < len(s) {
		return s[i+1:]
	}
	return s
}

// repeatsLabel reports whether a bracketed source says what the label
// already said: it names the same thing, or one of the label's segments,
// once case and punctuation are set aside.
func repeatsLabel(src, label string) bool {
	for _, seg := range strings.Split(label, ".") {
		if sameIdentity(src, seg) {
			return true
		}
	}
	return sameIdentity(src, label)
}

// sameIdentity reports whether two labels name the same thing once case and
// punctuation are set aside ("LeylineDaemon" and "leyline.daemon"). One may
// extend the other at either end, but only when the shorter half is a word in
// its own right: a short tag like [IO] says something the label does not, and
// a relay that drops it loses information.
func sameIdentity(a, b string) bool {
	x, y := identityKey(a), identityKey(b)
	if x == "" || y == "" {
		return false
	}
	if x == y {
		return true
	}
	const shortest = 4
	if len(x) > len(y) {
		x, y = y, x
	}
	return len(x) >= shortest && (strings.HasPrefix(y, x) || strings.HasSuffix(y, x))
}

// identityKey lowercases a label and drops everything but letters and digits.
func identityKey(s string) string {
	var out strings.Builder
	for _, r := range strings.ToLower(s) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			out.WriteRune(r)
		}
	}
	return out.String()
}
