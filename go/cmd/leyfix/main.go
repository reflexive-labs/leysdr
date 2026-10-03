// SPDX-License-Identifier: Apache-2.0

// Command leyfix generates, checks and inspects Leyline IQ fixtures.
//
//	leyfix generate --out DIR [--rate 2400000] [--duration 1] [--seed 1] [--only a,b] [--set scenes] [--dry-run]
//	leyfix check DIR|FILE...
//	leyfix info FILE
//
// See docs/reference/iq-files.md for the catalog and sidecar format.
package main

import (
	"fmt"
	"os"
)

const version = "0.1.0"

func usage() {
	fmt.Fprintln(os.Stderr, "usage: leyfix generate --out DIR [--rate HZ] [--duration S] [--seed N] [--only a,b] [--set scenes] [--dry-run]")
	fmt.Fprintln(os.Stderr, "       (--set scenes writes "+sceneNames()+")")
	fmt.Fprintln(os.Stderr, "       leyfix check DIR|FILE...")
	fmt.Fprintln(os.Stderr, "       leyfix info FILE")
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "generate":
		err = runGenerate(os.Args[2:], os.Stdout)
	case "check":
		err = runCheck(os.Args[2:], os.Stdout)
	case "info":
		err = runInfo(os.Args[2:], os.Stdout)
	case "-h", "--help", "help":
		usage()
		return
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "leyfix:", err)
		os.Exit(1)
	}
}
