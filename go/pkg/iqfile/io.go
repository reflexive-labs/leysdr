package iqfile

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"os"
)

// Writer streams complex samples to a .cf32 file as interleaved little-endian
// float32 I/Q. Samples are buffered and written block-wise; call Close.
type Writer struct {
	f     *os.File
	w     *bufio.Writer
	buf   []byte
	count int64
}

// NewWriter creates (truncating) the .cf32 file at path.
func NewWriter(path string) (*Writer, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	return &Writer{f: f, w: bufio.NewWriterSize(f, 1<<20), buf: make([]byte, 8*4096)}, nil
}

// Write appends a block of samples.
func (w *Writer) Write(block []complex64) error {
	for len(block) > 0 {
		n := min(len(block), len(w.buf)/8)
		for i, c := range block[:n] {
			binary.LittleEndian.PutUint32(w.buf[i*8:], math.Float32bits(real(c)))
			binary.LittleEndian.PutUint32(w.buf[i*8+4:], math.Float32bits(imag(c)))
		}
		if _, err := w.w.Write(w.buf[:n*8]); err != nil {
			return err
		}
		w.count += int64(n)
		block = block[n:]
	}
	return nil
}

// WriteComplex128 appends a block of float64 samples, narrowing to float32.
func (w *Writer) WriteComplex128(block []complex128) error {
	tmp := make([]complex64, 0, min(len(block), 4096))
	for len(block) > 0 {
		n := min(len(block), cap(tmp))
		tmp = tmp[:n]
		for i, c := range block[:n] {
			tmp[i] = complex(float32(real(c)), float32(imag(c)))
		}
		if err := w.Write(tmp); err != nil {
			return err
		}
		block = block[n:]
	}
	return nil
}

// Samples returns the number of samples written so far.
func (w *Writer) Samples() int64 { return w.count }

// Close flushes and closes the file.
func (w *Writer) Close() error {
	if err := w.w.Flush(); err != nil {
		_ = w.f.Close() // cleanup after a failed flush; the flush error is the one to report
		return err
	}
	return w.f.Close()
}

// Reader yields blocks of complex64 samples from a .cf32 or .cu8 file.
type Reader struct {
	f       *os.File
	r       *bufio.Reader
	format  string
	bps     int
	raw     []byte
	Samples int64 // total samples in the file, from its size
}

// Open opens the sample file at path (a .cf32/.cu8/.json path; resolved via
// SamplesPath) decoding according to format.
func Open(path, format string) (*Reader, error) {
	if format == "" {
		format = FormatCF32
	}
	if format != FormatCF32 && format != FormatCU8 {
		return nil, fmt.Errorf("iqfile: unsupported format %q", format)
	}
	p := SamplesPath(path, format)
	f, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	st, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return nil, err
	}
	bps := BytesPerSample(format)
	return &Reader{
		f: f, r: bufio.NewReaderSize(f, 1<<20), format: format, bps: bps,
		Samples: st.Size() / int64(bps),
	}, nil
}

// Read fills dst with the next samples and returns how many were decoded.
// It returns io.EOF (with n == 0) when the file is exhausted, and an error for
// an empty dst: the documented drain loop breaks on io.EOF, so answering "zero
// samples, no error" would spin forever.
func (r *Reader) Read(dst []complex64) (int, error) {
	if len(dst) == 0 {
		return 0, fmt.Errorf("iqfile: Read into an empty buffer")
	}
	need := len(dst) * r.bps
	if cap(r.raw) < need {
		r.raw = make([]byte, need)
	}
	raw := r.raw[:need]
	n, err := io.ReadFull(r.r, raw)
	n /= r.bps
	if n == 0 {
		if err == io.ErrUnexpectedEOF || err == io.EOF {
			return 0, io.EOF
		}
		return 0, err
	}
	switch r.format {
	case FormatCU8:
		for i := range n {
			dst[i] = complex((float32(raw[2*i])-127.5)/127.5, (float32(raw[2*i+1])-127.5)/127.5)
		}
	default:
		for i := range n {
			re := math.Float32frombits(binary.LittleEndian.Uint32(raw[8*i:]))
			im := math.Float32frombits(binary.LittleEndian.Uint32(raw[8*i+4:]))
			dst[i] = complex(re, im)
		}
	}
	return n, nil
}

// Close closes the underlying file.
func (r *Reader) Close() error { return r.f.Close() }

// ReadAll decodes the entire sample file into memory.
func ReadAll(path, format string) ([]complex64, error) {
	r, err := Open(path, format)
	if err != nil {
		return nil, err
	}
	defer r.Close()
	out := make([]complex64, 0, r.Samples)
	buf := make([]complex64, 8192)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			out = append(out, buf[:n]...)
		}
		if err == io.EOF {
			return out, nil
		}
		if err != nil {
			return nil, err
		}
	}
}
