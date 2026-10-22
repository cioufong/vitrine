package protocol

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"math"
)

// Errors mirroring AgentProtocolError.
var (
	ErrTruncated = errors.New("truncated agent message")
)

// UnknownTypeError reports an unrecognized message type byte.
type UnknownTypeError uint8

func (e UnknownTypeError) Error() string {
	return fmt.Sprintf("unknown agent message type 0x%x", uint8(e))
}

// MalformedError reports a structurally invalid payload.
type MalformedError string

func (e MalformedError) Error() string { return "malformed agent message: " + string(e) }

// TooLargeError reports a message exceeding MaxMessageSize.
type TooLargeError int

func (e TooLargeError) Error() string {
	return fmt.Sprintf("agent message too large (%d bytes)", int(e))
}

// FrameHeaderSize is the fixed binary header preceding frame pixels.
const FrameHeaderSize = 25

// Encode serializes a message including its length prefix.
func Encode(m Message) ([]byte, error) {
	head, body, err := EncodeParts(m)
	if err != nil {
		return nil, err
	}
	if len(body) == 0 {
		return head, nil
	}
	out := make([]byte, 0, len(head)+len(body))
	return append(append(out, head...), body...), nil
}

// EncodeParts serializes a message as (prefix+type+header, body). For frames
// the body is the pixel slice itself so large buffers are not copied; for all
// other messages body is nil. Writing head then body yields the exact wire bytes.
func EncodeParts(m Message) (head, body []byte, err error) {
	var payload []byte
	switch v := normalize(m).(type) {
	case Hello, WindowList, DisplayInfo, WindowAction, SetCoherence, Clipboard, FileDrop, MountShares,
		AppIconRequest, AppIcon, AppCatalogRequest, AppCatalog, LaunchApp, TimeSync, GuestNetwork, GuestStats,
		CameraStart, CameraStatus, BluetoothStatus:
		if payload, err = json.Marshal(v); err != nil {
			return nil, nil, err
		}
	case Log:
		payload = []byte(v)
	case CameraStop, BluetoothStart, BluetoothStop:
	case BluetoothHCI:
		payload = []byte(v)
	case CameraFrame:
		payload = binary.LittleEndian.AppendUint32(nil, v.Width)
		payload = binary.LittleEndian.AppendUint32(payload, v.Height)
		body = v.Data
	case Ping:
		payload = binary.LittleEndian.AppendUint64(nil, uint64(v))
	case Pong:
		payload = binary.LittleEndian.AppendUint64(nil, uint64(v))
	case Frame:
		payload = make([]byte, 0, FrameHeaderSize)
		for _, n := range []uint32{v.SurfaceWidth, v.SurfaceHeight, v.X, v.Y, v.Width, v.Height} {
			payload = binary.LittleEndian.AppendUint32(payload, n)
		}
		payload = append(payload, v.Encoding)
		body = v.Data
	case Pointer:
		payload = make([]byte, 0, 28)
		payload = append(payload, v.Kind, v.Button, v.ClickCount, boolByte(v.PreciseScroll))
		for _, f := range []float32{v.X, v.Y, v.ScrollDX, v.ScrollDY} {
			payload = binary.LittleEndian.AppendUint32(payload, math.Float32bits(f))
		}
		payload = binary.LittleEndian.AppendUint64(payload, v.Modifiers)
	case Key:
		payload = make([]byte, 0, 11+len(v.Text))
		payload = binary.LittleEndian.AppendUint16(payload, v.KeyCode)
		payload = append(payload, boolByte(v.Down))
		payload = binary.LittleEndian.AppendUint64(payload, v.Modifiers)
		payload = append(payload, v.Text...)
	default:
		return nil, nil, fmt.Errorf("protocol: cannot encode %T", m)
	}
	length := 1 + len(payload) + len(body)
	if length > MaxMessageSize {
		return nil, nil, TooLargeError(length)
	}
	head = make([]byte, 0, 5+len(payload))
	head = binary.LittleEndian.AppendUint32(head, uint32(length))
	head = append(head, byte(m.Type()))
	head = append(head, payload...)
	return head, body, nil
}

// normalize replaces nil slices with empty ones: Go marshals nil as JSON null,
// which Swift's non-optional arrays / Data reject.
func normalize(m Message) Message {
	switch v := m.(type) {
	case Hello:
		if v.Capabilities == nil {
			v.Capabilities = []string{}
		}
		return v
	case WindowList:
		if v.Windows == nil {
			v.Windows = []WindowInfo{}
		}
		return v
	case GuestNetwork:
		ifs := make([]NetInterface, len(v.Interfaces))
		for i, n := range v.Interfaces {
			if n.IPv4 == nil {
				n.IPv4 = []string{}
			}
			if n.IPv6 == nil {
				n.IPv6 = []string{}
			}
			ifs[i] = n
		}
		v.Interfaces = ifs
		return v
	case FileDrop:
		if v.Files == nil {
			v.Files = []string{}
		}
		return v
	case AppIcon:
		if v.PNG == nil {
			v.PNG = []byte{}
		}
		return v
	case AppCatalog:
		if v.Apps == nil {
			v.Apps = []CatalogApp{}
		}
		return v
	case MountShares:
		if v.Shares == nil {
			v.Shares = []MountShare{}
		}
		return v
	case Clipboard:
		items := make([]ClipboardItem, len(v.Items))
		for i, it := range v.Items {
			if it.Data == nil {
				it.Data = []byte{}
			}
			items[i] = it
		}
		v.Items = items
		return v
	}
	return m
}

func boolByte(b bool) byte {
	if b {
		return 1
	}
	return 0
}

// Decode decodes a message body (type byte + payload, without the length prefix).
func Decode(t uint8, payload []byte) (Message, error) {
	r := reader{b: payload}
	switch MessageType(t) {
	case TypeHello:
		return decodeJSON[Hello](payload)
	case TypeWindowList:
		return decodeJSON[WindowList](payload)
	case TypeDisplayInfo:
		return decodeJSON[DisplayInfo](payload)
	case TypeWindowAction:
		return decodeJSON[WindowAction](payload)
	case TypeSetCoherence:
		return decodeJSON[SetCoherence](payload)
	case TypeClipboard:
		return decodeJSON[Clipboard](payload)
	case TypeFileDrop:
		return decodeJSON[FileDrop](payload)
	case TypeMountShares:
		return decodeJSON[MountShares](payload)
	case TypeAppIconReq:
		return decodeJSON[AppIconRequest](payload)
	case TypeAppIcon:
		return decodeJSON[AppIcon](payload)
	case TypeAppCatReq:
		return decodeJSON[AppCatalogRequest](payload)
	case TypeAppCatalog:
		return decodeJSON[AppCatalog](payload)
	case TypeLaunchApp:
		return decodeJSON[LaunchApp](payload)
	case TypeTimeSync:
		return decodeJSON[TimeSync](payload)
	case TypeGuestNetwork:
		return decodeJSON[GuestNetwork](payload)
	case TypeGuestStats:
		return decodeJSON[GuestStats](payload)
	case TypeCameraStart:
		m, err := decodeJSON[CameraStart](payload)
		if err != nil {
			return nil, err
		}
		s := m.(CameraStart)
		if s.Width < 1 || s.Width > MaxCameraDimension || s.Height < 1 || s.Height > MaxCameraDimension || s.FPS < 1 || s.FPS > 120 {
			return nil, MalformedError("camera size")
		}
		return s, nil
	case TypeCameraStatus:
		return decodeJSON[CameraStatus](payload)
	case TypeCameraStop:
		return CameraStop{}, nil
	case TypeBTStart:
		return BluetoothStart{}, nil
	case TypeBTStop:
		return BluetoothStop{}, nil
	case TypeBTStatus:
		return decodeJSON[BluetoothStatus](payload)
	case TypeBTHCI:
		if len(payload) < 2 || len(payload) > MaxHCIPacket {
			return nil, MalformedError("HCI packet length")
		}
		return BluetoothHCI(append([]byte(nil), payload...)), nil
	case TypeCameraFrame:
		w, err := r.u32()
		if err != nil {
			return nil, err
		}
		h, err := r.u32()
		if err != nil {
			return nil, err
		}
		if w == 0 || h == 0 || w > MaxCameraDimension || h > MaxCameraDimension {
			return nil, MalformedError("camera frame size")
		}
		rest := r.rest()
		if uint64(len(rest)) != uint64(w)*uint64(h)*2 {
			return nil, MalformedError("camera frame length")
		}
		return CameraFrame{Width: w, Height: h, Data: append([]byte(nil), rest...)}, nil
	case TypeLog:
		return Log(payload), nil
	case TypePing:
		n, err := r.u64()
		return Ping(n), err
	case TypePong:
		n, err := r.u64()
		return Pong(n), err
	case TypeFrame:
		var f Frame
		for _, p := range []*uint32{&f.SurfaceWidth, &f.SurfaceHeight, &f.X, &f.Y, &f.Width, &f.Height} {
			v, err := r.u32()
			if err != nil {
				return nil, err
			}
			*p = v
		}
		enc, err := r.u8()
		if err != nil {
			return nil, err
		}
		if enc != EncodingRaw && enc != EncodingLZ4 {
			return nil, MalformedError("frame encoding")
		}
		f.Encoding = enc
		// The peer is untrusted: bound the surface before any arithmetic
		// (like Swift's AgentProtocol.maxSurfaceDimension) so w*h*4 cannot
		// wrap — 2³¹×2³¹×4 overflows uint64 to 0.
		if f.SurfaceWidth == 0 || f.SurfaceHeight == 0 ||
			f.SurfaceWidth > MaxSurfaceDimension || f.SurfaceHeight > MaxSurfaceDimension {
			return nil, MalformedError(fmt.Sprintf("surface size %dx%d", f.SurfaceWidth, f.SurfaceHeight))
		}
		if uint64(f.X)+uint64(f.Width) > uint64(f.SurfaceWidth) || uint64(f.Y)+uint64(f.Height) > uint64(f.SurfaceHeight) {
			return nil, MalformedError("frame rect outside surface")
		}
		rest := r.rest()
		if enc == EncodingRaw && uint64(len(rest)) != uint64(f.Width)*uint64(f.Height)*4 {
			return nil, MalformedError(fmt.Sprintf("raw frame size %d != %dx%dx4", len(rest), f.Width, f.Height))
		}
		f.Data = append([]byte(nil), rest...)
		return f, nil
	case TypePointer:
		if len(payload) < 28 {
			return nil, ErrTruncated
		}
		p := Pointer{Kind: payload[0], Button: payload[1], ClickCount: payload[2], PreciseScroll: payload[3] != 0}
		if p.Kind > PointerScroll || p.Button > ButtonOther {
			return nil, MalformedError("pointer")
		}
		le := binary.LittleEndian
		p.X = math.Float32frombits(le.Uint32(payload[4:]))
		p.Y = math.Float32frombits(le.Uint32(payload[8:]))
		p.ScrollDX = math.Float32frombits(le.Uint32(payload[12:]))
		p.ScrollDY = math.Float32frombits(le.Uint32(payload[16:]))
		p.Modifiers = le.Uint64(payload[20:])
		return p, nil
	case TypeKey:
		if len(payload) < 11 {
			return nil, ErrTruncated
		}
		le := binary.LittleEndian
		return Key{
			KeyCode:   le.Uint16(payload),
			Down:      payload[2] != 0,
			Modifiers: le.Uint64(payload[3:]),
			Text:      string(payload[11:]),
		}, nil
	}
	return nil, UnknownTypeError(t)
}

func decodeJSON[T Message](payload []byte) (Message, error) {
	var v T
	if err := json.Unmarshal(payload, &v); err != nil {
		return nil, MalformedError(err.Error())
	}
	return v, nil
}

type reader struct {
	b   []byte
	off int
}

func (r *reader) take(n int) ([]byte, error) {
	if r.off+n > len(r.b) {
		return nil, ErrTruncated
	}
	s := r.b[r.off : r.off+n]
	r.off += n
	return s, nil
}

func (r *reader) u8() (uint8, error) {
	s, err := r.take(1)
	if err != nil {
		return 0, err
	}
	return s[0], nil
}

func (r *reader) u32() (uint32, error) {
	s, err := r.take(4)
	if err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint32(s), nil
}

func (r *reader) u64() (uint64, error) {
	s, err := r.take(8)
	if err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint64(s), nil
}

func (r *reader) rest() []byte { s := r.b[r.off:]; r.off = len(r.b); return s }
