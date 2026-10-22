package protocol

import (
	"encoding/binary"
	"io"
)

// Deframer is an incremental stream deframer: append bytes as they arrive and
// pull complete messages out with Next.
type Deframer struct {
	buf []byte
}

// Append buffers more stream bytes.
func (d *Deframer) Append(b []byte) { d.buf = append(d.buf, b...) }

// Buffered reports how many bytes are waiting.
func (d *Deframer) Buffered() int { return len(d.buf) }

// Next returns the next complete message, or (nil, nil) if more bytes are needed.
func (d *Deframer) Next() (Message, error) {
	if len(d.buf) < 5 {
		return nil, nil
	}
	length := int(binary.LittleEndian.Uint32(d.buf))
	if length < 1 {
		return nil, MalformedError("zero-length message")
	}
	if length > MaxMessageSize {
		return nil, TooLargeError(length)
	}
	if len(d.buf) < 4+length {
		return nil, nil
	}
	t := d.buf[4]
	payload := d.buf[5 : 4+length]
	m, err := Decode(t, payload)
	// Decode copies anything it keeps, so the consumed prefix can be dropped.
	rest := len(d.buf) - (4 + length)
	if rest == 0 {
		d.buf = d.buf[:0]
	} else {
		copy(d.buf, d.buf[4+length:])
		d.buf = d.buf[:rest]
	}
	return m, err
}

// ReadLoop reads r until EOF/error, calling fn for each decoded message.
// It returns nil on clean EOF.
func ReadLoop(r io.Reader, fn func(Message)) error {
	var d Deframer
	buf := make([]byte, 1<<20)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			d.Append(buf[:n])
			for {
				m, derr := d.Next()
				if derr != nil {
					return derr
				}
				if m == nil {
					break
				}
				fn(m)
			}
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
	}
}
