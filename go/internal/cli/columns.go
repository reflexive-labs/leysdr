// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"io"
	"strings"

	"github.com/dpup/leysdr/go/internal/ui"
)

// column is one column of an aligned table. Cells arrive already inked: the
// renderer measures visible width and pads with ui.Style.Pad, so SGR inside a
// cell cannot move a column the way it would inside a tabwriter cell
// (docs/dev/cli-style.md section 3).
type column struct {
	// head is the ALL-CAPS header; the renderer gives it Label ink.
	head string
	// cells holds one entry per row, in row order.
	cells []string
	// min, when above zero, is the narrowest this column may be truncated to
	// before the table gives up and drops it.
	min int
	// drop, when above zero, marks the column droppable once the table is
	// over its width budget: the highest rank goes first. A column with no
	// rank is essential and is never dropped.
	drop int
	// hideEmpty leaves the column out when every row holds the absent
	// glyph: a column of nothing but "-" wastes width (docs/dev/cli-style.md
	// section 5). An empty table keeps it, so the header still shows what a
	// row would carry.
	hideEmpty bool
	// right aligns the column, header included, on its right edge: a numeric
	// column, whose header carries the unit, so the digits line up and a
	// short number does not sit at the far left of a wide header with air
	// after it.
	right bool
}

// withoutEmpty applies hideEmpty.
func withoutEmpty(cols []column) []column {
	out := make([]column, 0, len(cols))
	for _, c := range cols {
		if c.hideEmpty && len(c.cells) > 0 && !anyPresent(c.cells) {
			continue
		}
		out = append(out, c)
	}
	return out
}

// anyPresent reports whether any cell holds a value rather than the absent glyph.
func anyPresent(cells []string) bool {
	for _, c := range cells {
		if c != "-" && c != "" {
			return true
		}
	}
	return false
}

// gutter is the two spaces between columns; docs/dev/cli-style.md section 5.
const gutter = 2

// tableStyle is stdout's style with the width budget a table should honour.
// A pipe has no width: the resolved 80 is a chart's fallback, and applying it
// to a table would quietly cut columns out of `ley devices | grep`. So a
// table fits itself to the terminal it is on, and prints whole into a pipe.
func tableStyle(a *App) ui.Style {
	s := a.Style
	if a.IsTTY == nil || !a.IsTTY() {
		s.Width = 0
	}
	return s
}

// printColumns writes an aligned table: the header row in Label ink, then one
// line per row. groups, when non-nil, carries one entry per row naming the
// Label sub-heading to print before it ("" continues the current group), and
// puts the whole table under a two-space indent so the headings stand out.
//
// Columns are fitted to s.Width when it is known: flexible columns shrink to
// their minimum first, then droppable columns are dropped by rank. A table
// whose mandatory columns do not fit is printed wide rather than mangled.
// It returns the heads of the columns it had to drop, so a caller can tell
// the reader what is missing and how to get it back.
func printColumns(w io.Writer, s ui.Style, cols []column, groups []string) ([]string, error) {
	cols = withoutEmpty(cols)
	indent := ""
	if groups != nil {
		indent = "  "
	}
	widths := fit(cols, s.Width-len(indent))
	last := lastVisible(widths)
	var b strings.Builder
	line := func(cells []string) {
		b.WriteString(indent)
		for i, c := range cells {
			if widths[i] < 0 {
				continue
			}
			c = s.Truncate(c, widths[i])
			if cols[i].right {
				c = strings.Repeat(" ", widths[i]-ui.Visible(c)) + c
			}
			if i == last {
				b.WriteString(c)
				break
			}
			b.WriteString(s.Pad(c, widths[i]))
			b.WriteString(strings.Repeat(" ", gutter))
		}
		trimTrailing(&b)
		b.WriteByte('\n')
	}
	heads := make([]string, len(cols))
	for i, c := range cols {
		heads[i] = s.Label(c.head)
	}
	line(heads)
	for r := 0; r < rows(cols); r++ {
		if groups != nil && groups[r] != "" {
			b.WriteString(s.Label(groups[r]))
			b.WriteByte('\n')
		}
		cells := make([]string, len(cols))
		for i, c := range cols {
			if r < len(c.cells) {
				cells[i] = c.cells[r]
			}
		}
		line(cells)
	}
	var dropped []string
	for i, width := range widths {
		if width < 0 {
			dropped = append(dropped, cols[i].head)
		}
	}
	_, err := io.WriteString(w, b.String())
	return dropped, err
}

// rows is the number of body rows across the columns.
func rows(cols []column) int {
	n := 0
	for _, c := range cols {
		if len(c.cells) > n {
			n = len(c.cells)
		}
	}
	return n
}

// lastVisible is the index of the rightmost column that survived fitting; its
// cell is written unpadded so no line ends in a run of spaces.
func lastVisible(widths []int) int {
	last := -1
	for i, w := range widths {
		if w >= 0 {
			last = i
		}
	}
	return last
}

// trimTrailing removes the spaces a padded final cell would leave at the end
// of a line, so a copied line carries no invisible tail.
func trimTrailing(b *strings.Builder) {
	s := strings.TrimRight(b.String(), " ")
	b.Reset()
	b.WriteString(s)
}

// fit returns each column's rendered width, or -1 for a column dropped to
// meet the budget. A budget at or below zero means the width is unknown, and
// every column is printed at its natural size.
func fit(cols []column, budget int) []int {
	widths := make([]int, len(cols))
	for i, c := range cols {
		widths[i] = ui.Visible(c.head)
		for _, cell := range c.cells {
			if v := ui.Visible(cell); v > widths[i] {
				widths[i] = v
			}
		}
	}
	if budget <= 0 {
		return widths
	}
	// Shrink the flexible columns, widest first, then drop the droppable
	// ones by rank: a column cut below its minimum is unreadable.
	for total(widths) > budget {
		i := widestFlexible(cols, widths)
		if i < 0 {
			break
		}
		widths[i]--
	}
	for total(widths) > budget {
		i := nextToDrop(cols, widths)
		if i < 0 {
			break
		}
		widths[i] = -1
	}
	return widths
}

// total is the width of a row: the visible columns plus their gutters.
func total(widths []int) int {
	sum, n := 0, 0
	for _, w := range widths {
		if w < 0 {
			continue
		}
		sum += w
		n++
	}
	if n > 1 {
		sum += (n - 1) * gutter
	}
	return sum
}

// widestFlexible is the visible column with the most room left above its
// minimum, or -1 when nothing can shrink further.
func widestFlexible(cols []column, widths []int) int {
	best, slack := -1, 0
	for i, c := range cols {
		if c.min <= 0 || widths[i] < 0 {
			continue
		}
		if s := widths[i] - c.min; s > slack {
			best, slack = i, s
		}
	}
	return best
}

// nextToDrop is the least important visible column, or -1 when only
// mandatory columns remain.
func nextToDrop(cols []column, widths []int) int {
	best, rank := -1, 0
	for i, c := range cols {
		if c.drop <= 0 || widths[i] < 0 {
			continue
		}
		if c.drop > rank {
			best, rank = i, c.drop
		}
	}
	return best
}
