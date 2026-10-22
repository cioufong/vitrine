package protocol

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"reflect"
	"testing"
)

func stream(t *testing.T, msgs []Message) []byte {
	var out []byte
	for _, m := range msgs {
		b, err := Encode(m)
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, b...)
	}
	return out
}

func drain(t *testing.T, d *Deframer) []Message {
	var got []Message
	for {
		m, err := d.Next()
		if err != nil {
			t.Fatal(err)
		}
		if m == nil {
			return got
		}
		got = append(got, m)
	}
}

func TestDeframerByteByByte(t *testing.T) {
	msgs := sampleMessages()
	all := stream(t, msgs)
	var d Deframer
	var got []Message
	for i := range all {
		d.Append(all[i : i+1])
		got = append(got, drain(t, &d)...)
	}
	if !reflect.DeepEqual(got, msgs) {
		t.Fatalf("byte-by-byte: got %d messages, want %d", len(got), len(msgs))
	}
}

func TestDeframerCoalescedAndSplit(t *testing.T) {
	msgs := sampleMessages()
	all := stream(t, msgs)
	// Everything at once.
	var d Deframer
	d.Append(all)
	if got := drain(t, &d); !reflect.DeepEqual(got, msgs) {
		t.Fatal("coalesced read mismatch")
	}
	// Uneven chunks that straddle headers and payloads.
	for _, chunk := range []int{2, 3, 7, 13, 64} {
		var d Deframer
		var got []Message
		for off := 0; off < len(all); off += chunk {
			end := off + chunk
			if end > len(all) {
				end = len(all)
			}
			d.Append(all[off:end])
			got = append(got, drain(t, &d)...)
		}
		if !reflect.DeepEqual(got, msgs) {
			t.Fatalf("chunk %d mismatch", chunk)
		}
	}
}

func TestDeframerNeedsMoreBytes(t *testing.T) {
	b, _ := Encode(Ping(5))
	var d Deframer
	d.Append(b[:4])
	if m, err := d.Next(); m != nil || err != nil {
		t.Fatalf("partial header: %v %v", m, err)
	}
	d.Append(b[4:8])
	if m, err := d.Next(); m != nil || err != nil {
		t.Fatalf("partial payload: %v %v", m, err)
	}
	d.Append(b[8:])
	if m, err := d.Next(); err != nil || m != Ping(5) {
		t.Fatalf("complete: %v %v", m, err)
	}
}

func TestDeframerRejectsBadLengths(t *testing.T) {
	var d Deframer
	d.Append([]byte{0, 0, 0, 0, 0x30})
	if _, err := d.Next(); !errors.As(err, new(MalformedError)) {
		t.Errorf("zero length: %v", err)
	}
	var d2 Deframer
	hdr := binary.LittleEndian.AppendUint32(nil, MaxMessageSize+1)
	d2.Append(append(hdr, 0x03))
	if _, err := d2.Next(); !errors.As(err, new(TooLargeError)) {
		t.Errorf("too large: %v", err)
	}
}

type chunkReader struct {
	data  []byte
	chunk int
}

func (r *chunkReader) Read(p []byte) (int, error) {
	if len(r.data) == 0 {
		return 0, io.EOF
	}
	n := r.chunk
	if n > len(p) {
		n = len(p)
	}
	if n > len(r.data) {
		n = len(r.data)
	}
	copy(p, r.data[:n])
	r.data = r.data[n:]
	return n, nil
}

func TestReadLoop(t *testing.T) {
	msgs := sampleMessages()
	var got []Message
	err := ReadLoop(&chunkReader{data: stream(t, msgs), chunk: 5}, func(m Message) { got = append(got, m) })
	if err != nil || !reflect.DeepEqual(got, msgs) {
		t.Fatalf("ReadLoop: err=%v, %d messages", err, len(got))
	}
	if err := ReadLoop(bytes.NewReader([]byte{0, 0, 0, 0, 1}), func(Message) {}); err == nil {
		t.Fatal("expected error on malformed stream")
	}
}
