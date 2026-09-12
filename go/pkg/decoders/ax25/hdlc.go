// SPDX-License-Identifier: Apache-2.0

package ax25

// FCS is the AX.25 frame check sequence: CRC-16 X.25, the reflected CCITT
// polynomial 0x8408, initialised to 0xFFFF and complemented at the end. It is
// sent low byte first.
func FCS(data []byte) uint16 {
	crc := uint16(0xFFFF)
	for _, b := range data {
		crc ^= uint16(b)
		for i := 0; i < 8; i++ {
			if crc&1 != 0 {
				crc = crc>>1 ^ 0x8408
			} else {
				crc >>= 1
			}
		}
	}
	return ^crc
}

// CheckFCS reports whether a frame's trailing two bytes are its own FCS.
func CheckFCS(frame []byte) bool {
	if len(frame) < 3 {
		return false
	}
	body, sum := frame[:len(frame)-2], frame[len(frame)-2:]
	want := FCS(body)
	return sum[0] == byte(want) && sum[1] == byte(want>>8)
}

// Deframer turns a bit stream into frames. Bits arrive in transmission order,
// least significant bit of each byte first, already NRZI-decoded.
type Deframer struct {
	onesRun    int
	collecting bool
	bitBuf     byte
	bitCount   int
	frame      []byte

	// Frames counts every flag-delimited candidate seen and Bad those whose
	// FCS failed, so a caller can report how noisy the channel was.
	Frames int
	Bad    int
}

// NewDeframer returns a deframer waiting for its first flag.
func NewDeframer() *Deframer { return &Deframer{} }

// Reset forgets a partial frame. A gap in the stream invalidates it.
func (d *Deframer) Reset() {
	d.onesRun, d.collecting, d.bitBuf, d.bitCount = 0, false, 0, 0
	d.frame = d.frame[:0]
}

// Feed pushes one bit. emit is called for each frame whose FCS checks out,
// with the frame bytes (flags and FCS removed) and the sample index the caller
// passed with the bit that closed it.
func (d *Deframer) Feed(bit bool, at int64, emit func(raw []byte, at int64)) {
	switch {
	case d.onesRun == 5:
		if !bit {
			// The stuffed zero after five ones: drop it.
			d.onesRun = 0
			return
		}
		d.onesRun = 6
		return
	case d.onesRun == 6:
		if !bit {
			d.closeFrame(at, emit)
			d.onesRun = 0
			d.collecting = true
			return
		}
		// Seven ones: an abort, or the idle line between packets.
		d.abort()
		d.onesRun = 7
		return
	case d.onesRun >= 7:
		if bit {
			return
		}
		d.onesRun = 0
		return
	}
	if bit {
		d.onesRun++
	} else {
		d.onesRun = 0
	}
	d.add(bit)
}

func (d *Deframer) add(bit bool) {
	if !d.collecting {
		return
	}
	if bit {
		d.bitBuf |= 1 << d.bitCount
	}
	d.bitCount++
	if d.bitCount == 8 {
		d.frame = append(d.frame, d.bitBuf)
		d.bitBuf, d.bitCount = 0, 0
		if len(d.frame) > MaxFrame {
			d.abort()
		}
	}
}

func (d *Deframer) abort() {
	d.collecting = false
	d.bitBuf, d.bitCount = 0, 0
	d.frame = d.frame[:0]
}

// closeFrame is called on a flag. The six bits of the flag that were taken for
// data (its leading zero and the first five ones) sit in the partial byte and
// are dropped with it, which is why a frame is only accepted on whole bytes.
func (d *Deframer) closeFrame(at int64, emit func([]byte, int64)) {
	defer func() {
		d.bitBuf, d.bitCount = 0, 0
		d.frame = d.frame[:0]
	}()
	if !d.collecting || len(d.frame) < MinFrame {
		return
	}
	d.Frames++
	if !CheckFCS(d.frame) {
		d.Bad++
		return
	}
	raw := make([]byte, len(d.frame)-2)
	copy(raw, d.frame[:len(d.frame)-2])
	emit(raw, at)
}

// Encode turns a frame's bytes into a bit stream: preamble flags, the frame
// with its FCS and bit stuffing, then a closing flag. The result is data bits
// in transmission order, before NRZI.
func Encode(frame []byte, preambleFlags int) []bool {
	if preambleFlags < 1 {
		preambleFlags = 1
	}
	sum := FCS(frame)
	body := make([]byte, 0, len(frame)+2)
	body = append(body, frame...)
	body = append(body, byte(sum), byte(sum>>8))

	bits := make([]bool, 0, (preambleFlags+len(body)+2)*9)
	for i := 0; i < preambleFlags; i++ {
		bits = appendFlag(bits)
	}
	ones := 0
	for _, b := range body {
		for k := 0; k < 8; k++ {
			bit := b>>k&1 != 0
			bits = append(bits, bit)
			if bit {
				ones++
				if ones == 5 {
					bits = append(bits, false)
					ones = 0
				}
			} else {
				ones = 0
			}
		}
	}
	return appendFlag(bits)
}

func appendFlag(bits []bool) []bool {
	return append(bits, false, true, true, true, true, true, true, false)
}
