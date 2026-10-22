package protocol

import (
	"errors"
	"testing"
)

func TestFrameBoundsAndOverflow(t *testing.T) {
	bad := []struct {
		name string
		f    Frame
	}{
		// w*h*4 = 2^64 wraps to 0 in uint64: must not be accepted with no pixels.
		{"2^31 x 2^31 overflow", Frame{SurfaceWidth: 1 << 31, SurfaceHeight: 1 << 31, Width: 1 << 31, Height: 1 << 31}},
		{"max u32 surface", Frame{SurfaceWidth: ^uint32(0), SurfaceHeight: ^uint32(0), Width: 1 << 31, Height: 1 << 31}},
		{"zero surface width", Frame{SurfaceWidth: 0, SurfaceHeight: 10}},
		{"zero surface height", Frame{SurfaceWidth: 10, SurfaceHeight: 0}},
		{"surface wider than 8192", Frame{SurfaceWidth: MaxSurfaceDimension + 1, SurfaceHeight: 10}},
		{"surface taller than 8192", Frame{SurfaceWidth: 10, SurfaceHeight: MaxSurfaceDimension + 1}},
		{"x+w wraps uint32", Frame{SurfaceWidth: 8192, SurfaceHeight: 8, X: ^uint32(0), Width: 2, Height: 1, Data: make([]byte, 8)}},
		{"y+h wraps uint32", Frame{SurfaceWidth: 8, SurfaceHeight: 8192, Y: ^uint32(0) - 1, Width: 1, Height: 3, Data: make([]byte, 12)}},
	}
	for _, c := range bad {
		b, err := Encode(c.f)
		if err != nil {
			t.Fatalf("%s: encode: %v", c.name, err)
		}
		if _, err := Decode(b[4], b[5:]); !errors.As(err, new(MalformedError)) {
			t.Errorf("%s: want MalformedError, got %v", c.name, err)
		}
		// The deframer path must reject it too.
		var d Deframer
		d.Append(b)
		if _, err := d.Next(); !errors.As(err, new(MalformedError)) {
			t.Errorf("%s: deframer: want MalformedError, got %v", c.name, err)
		}
	}
	ok := []Frame{
		{SurfaceWidth: MaxSurfaceDimension, SurfaceHeight: MaxSurfaceDimension, X: MaxSurfaceDimension - 1,
			Y: MaxSurfaceDimension - 1, Width: 1, Height: 1, Data: make([]byte, 4)},
		{SurfaceWidth: 1, SurfaceHeight: 1, Width: 0, Height: 0, Data: []byte{}},
	}
	for _, f := range ok {
		b, _ := Encode(f)
		if _, err := Decode(b[4], b[5:]); err != nil {
			t.Errorf("valid frame %+v rejected: %v", f, err)
		}
	}
}
