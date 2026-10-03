// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/csv"
	"fmt"
	"html"
	"io"
	"slices"
	"strings"
)

// tableHTML draws the first t.Rows rows of a CSV (all of them when Rows is 0) as a table in the
// terminal theme, keeping t.Columns in that order (all of them when empty). A column the file
// does not have is an error naming it. When rows are left out, a last row of ellipses says so.
func tableHTML(title string, t *Table, r io.Reader) (string, error) {
	rows, err := csv.NewReader(r).ReadAll()
	if err != nil {
		return "", err
	}
	if len(rows) == 0 {
		return "", fmt.Errorf("%s is empty", t.Source)
	}
	header, body := rows[0], rows[1:]
	cols := make([]int, 0, len(header))
	if len(t.Columns) == 0 {
		for i := range header {
			cols = append(cols, i)
		}
	}
	for _, name := range t.Columns {
		i := slices.Index(header, name)
		if i < 0 {
			return "", fmt.Errorf("%s has no column %q", t.Source, name)
		}
		cols = append(cols, i)
	}
	shown := body
	if t.Rows > 0 && len(body) > t.Rows {
		shown = body[:t.Rows]
	}
	var b strings.Builder
	fmt.Fprintf(&b, "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>%s</title><style>\n%s", html.EscapeString(title), themeCSS())
	fmt.Fprintf(&b, "table{border-collapse:collapse;margin:%dpx}\n", paddingPx)
	b.WriteString("th{color:var(--bold);font-weight:bold;text-align:left;border-bottom:1px solid var(--rule)}\n")
	b.WriteString("th,td{padding:2px 14px 2px 0;white-space:pre}\n")
	b.WriteString("</style></head><body><table>\n<tr>")
	for _, c := range cols {
		fmt.Fprintf(&b, "<th>%s</th>", html.EscapeString(header[c]))
	}
	b.WriteString("</tr>\n")
	for _, row := range shown {
		b.WriteString("<tr>")
		for _, c := range cols {
			cell := ""
			if c < len(row) {
				cell = row[c]
			}
			fmt.Fprintf(&b, "<td>%s</td>", html.EscapeString(cell))
		}
		b.WriteString("</tr>\n")
	}
	if len(shown) < len(body) {
		b.WriteString("<tr>")
		for range cols {
			b.WriteString("<td>…</td>")
		}
		b.WriteString("</tr>\n")
	}
	b.WriteString("</table></body></html>\n")
	return b.String(), nil
}
