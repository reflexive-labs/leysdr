// SPDX-License-Identifier: Apache-2.0

// Package ax25 deframes and frames AX.25 over HDLC: flag detection, bit
// stuffing, the X.25 FCS, and the address field. It is the layer between the
// afsk bit stream and the aprs parser.
package ax25

import (
	"errors"
	"fmt"
	"strings"
)

// Flag is the HDLC frame delimiter, 01111110.
const Flag = 0x7E

// MinFrame is the shortest legal AX.25 frame: two addresses, a control byte
// and the FCS. MaxFrame is the largest this deframer will assemble; a longer
// run of bits without a flag is noise, not a packet.
const (
	MinFrame = 17
	MaxFrame = 512
)

// Address is one callsign in the address field.
type Address struct {
	Call string
	SSID int
	// Repeated is the H bit on a digipeater address: this station has already
	// repeated the frame. On the destination and source addresses the same bit
	// is the command/response C bit.
	Repeated bool
}

// String renders the address as CALL-SSID, dropping a zero SSID.
func (a Address) String() string {
	if a.SSID == 0 {
		return a.Call
	}
	return fmt.Sprintf("%s-%d", a.Call, a.SSID)
}

// Frame is a parsed AX.25 frame. Raw is the frame as received, without the
// flags or the FCS, which is what DecodeRecord.raw carries.
type Frame struct {
	Dest    Address
	Source  Address
	Path    []Address
	Control byte
	PID     byte
	Info    []byte
	Raw     []byte
}

// UI reports whether this is an unnumbered information frame, the only kind
// APRS uses.
func (f *Frame) UI() bool { return f.Control&^0x10 == 0x03 }

// String renders the TNC2 monitor form, SRC>DST,PATH*:info, with a star after
// each digipeater that has already repeated the frame.
func (f *Frame) String() string {
	var b strings.Builder
	b.WriteString(f.Source.String())
	b.WriteByte('>')
	b.WriteString(f.Dest.String())
	for _, d := range f.Path {
		b.WriteByte(',')
		b.WriteString(d.String())
		if d.Repeated {
			b.WriteByte('*')
		}
	}
	b.WriteByte(':')
	b.Write(f.Info)
	return b.String()
}

// PathString renders the digipeater list the way TNC2 does, for DecodeRecord.fields.
func (f *Frame) PathString() string {
	parts := make([]string, 0, len(f.Path))
	for _, d := range f.Path {
		s := d.String()
		if d.Repeated {
			s += "*"
		}
		parts = append(parts, s)
	}
	return strings.Join(parts, ",")
}

var errShort = errors.New("ax25: frame shorter than two addresses")

// Parse reads the address, control and PID fields of a frame whose FCS has
// already been checked and removed.
func Parse(raw []byte) (*Frame, error) {
	if len(raw) < 15 {
		return nil, errShort
	}
	f := &Frame{Raw: raw}
	var addrs []Address
	last := false
	off := 0
	for off+7 <= len(raw) && !last {
		a, end := parseAddress(raw[off : off+7])
		addrs = append(addrs, a)
		last = end
		off += 7
		if len(addrs) > 10 {
			return nil, errors.New("ax25: address field has no end")
		}
	}
	if !last || len(addrs) < 2 {
		return nil, errShort
	}
	f.Dest, f.Source, f.Path = addrs[0], addrs[1], addrs[2:]
	if off >= len(raw) {
		return nil, errors.New("ax25: no control field")
	}
	f.Control = raw[off]
	off++
	if f.UI() && off < len(raw) {
		f.PID = raw[off]
		off++
	}
	f.Info = raw[off:]
	return f, nil
}

// parseAddress decodes one 7-byte address and reports whether its extension
// bit says it is the last one.
func parseAddress(b []byte) (Address, bool) {
	var call strings.Builder
	for i := 0; i < 6; i++ {
		c := b[i] >> 1
		if c != ' ' && c != 0 {
			call.WriteByte(c)
		}
	}
	return Address{
		Call:     call.String(),
		SSID:     int(b[6]>>1) & 0x0F,
		Repeated: b[6]&0x80 != 0,
	}, b[6]&0x01 != 0
}

// EncodeAddress writes one address in AX.25 form. last sets the extension bit
// that ends the address field.
func EncodeAddress(a Address, last bool) []byte {
	out := make([]byte, 7)
	call := strings.ToUpper(a.Call)
	for i := 0; i < 6; i++ {
		c := byte(' ')
		if i < len(call) {
			c = call[i]
		}
		out[i] = c << 1
	}
	// Bit 6 is reserved and transmitted as 1 by every TNC; bit 5 is the
	// reserved bit likewise.
	out[6] = 0x60 | byte(a.SSID&0x0F)<<1
	if a.Repeated {
		out[6] |= 0x80
	}
	if last {
		out[6] |= 0x01
	}
	return out
}

// BuildUI assembles a UI frame's bytes (addresses, control, PID, info),
// without the FCS or flags.
func BuildUI(dest, source Address, path []Address, pid byte, info []byte) []byte {
	out := make([]byte, 0, 16+len(path)*7+len(info))
	out = append(out, EncodeAddress(dest, false)...)
	out = append(out, EncodeAddress(source, len(path) == 0)...)
	for i, d := range path {
		out = append(out, EncodeAddress(d, i == len(path)-1)...)
	}
	out = append(out, 0x03, pid)
	return append(out, info...)
}
