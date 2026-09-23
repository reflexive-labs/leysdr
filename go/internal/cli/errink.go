// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"strings"

	"github.com/dpup/leysdr/go/internal/ui"
)

// The error line is "ley: <sentence> [CODE]" and stays that shape: the ink
// below only marks where the sentence begins, which part is a path that can
// be skipped, and which part is a command to type. Everything here
// is redundant emphasis -- ui.Strip of any of it is the plain line, byte for
// byte -- and ExitError.Message itself is never touched, so the tests that
// inspect it keep inspecting a plain string.

// remedyLeads introduce the "what to do next" clause of the standard error
// shape. The clause that follows one of these is a command to type.
var remedyLeads = []string{
	"Start it with: ", "start it with: ", "Check with: ", "check with: ",
	"Run: ", "run: ", "Look at its log: ", "adjust with: ", "change one with: ",
	// "use ley scan, which sweeps": the daemon's own remedies lead this way.
	"use ",
}

// ErrorLine renders one "ley: <message>" line for stderr with the resolved
// stderr style. The message is the verb's own words; only the prefix, a
// parenthetical path, the remedy command and a trailing [CODE] take ink.
func (a *App) ErrorLine(msg string) string {
	return errorLine(a.ErrStyle, msg)
}

// errorLine is ErrorLine's renderer, taking the style explicitly so it can be
// rendered twice in a test.
func errorLine(st ui.Style, msg string) string {
	if msg == "" {
		return st.Err("ley:")
	}
	return st.Err("ley:") + " " + inkMessage(st, msg)
}

// inkMessage inks the body of an error or status sentence: a parenthetical
// that holds a path is Muted (it is evidence, not instruction), the remedy
// command after a "…with: " lead is Cmd, the daemon's state words take Err,
// and a trailing machine code is Muted. Strip(inkMessage(st, s)) == s.
func inkMessage(st ui.Style, msg string) string {
	if !st.Color {
		return msg
	}
	lines := strings.Split(msg, "\n")
	for i, line := range lines {
		line = inkCode(st, line)
		line = inkPaths(st, line)
		line = inkRemedy(st, line)
		lines[i] = inkNotRunning(st, line)
	}
	return strings.Join(lines, "\n")
}

// inkCode Mutes a trailing "[CODE]": the daemon's stable code is for a script
// to grep, not for the reader to read first.
func inkCode(st ui.Style, line string) string {
	if !strings.HasSuffix(line, "]") {
		return line
	}
	i := strings.LastIndex(line, "[")
	if i < 0 {
		return line
	}
	code := line[i+1 : len(line)-1]
	if code == "" || code != strings.ToUpper(code) || strings.ContainsAny(code, " \t") {
		return line
	}
	return line[:i] + st.Muted("["+code+"]")
}

// inkPaths Mutes every parenthetical that holds a filesystem path, such as
// "(socket /tmp/leyline.sock)" -- the path is there for reference, not as
// the point of the message. Parentheticals that list accepted values are left
// alone.
func inkPaths(st ui.Style, line string) string {
	var b strings.Builder
	for {
		i := strings.Index(line, "(")
		if i < 0 {
			break
		}
		j := strings.Index(line[i:], ")")
		if j < 0 {
			break
		}
		inner := line[i : i+j+1]
		b.WriteString(line[:i])
		if strings.Contains(inner, "/") {
			b.WriteString(st.Muted(inner))
		} else {
			b.WriteString(inner)
		}
		line = line[i+j+1:]
	}
	b.WriteString(line)
	return b.String()
}

// inkRemedy gives the trailing "ley …" command of a sentence the Cmd ink, so
// the command to type stands out even when the line wraps.
func inkRemedy(st ui.Style, line string) string {
	best := -1
	for _, lead := range remedyLeads {
		if i := strings.LastIndex(line, lead); i >= 0 && i+len(lead) > best {
			best = i + len(lead)
		}
	}
	if best < 0 || !strings.HasPrefix(line[best:], "ley ") {
		return line
	}
	rest := line[best:]
	end := len(rest)
	// The clause ends at the sentence, not at the line: a following aside
	// ("(...)"), a new clause (";") or ink another rule already applied is
	// not part of the command.
	if i := strings.IndexAny(rest, ";,(\x1b"); i > 0 {
		end = i
	}
	cmd := strings.TrimRight(rest[:end], " .")
	if cmd == "" {
		return line
	}
	return line[:best] + st.Cmd(cmd) + rest[len(cmd):]
}

// inkNotRunning gives the daemon's state words Err ink in the sentence every
// verb shares. The words carry the meaning; the colour only highlights them.
func inkNotRunning(st ui.Style, line string) string {
	const state = "is not running"
	if !strings.Contains(line, "the Leyline daemon "+state) {
		return line
	}
	i := strings.Index(line, state)
	return line[:i] + "is " + st.Err("not running") + line[i+len(state):]
}
