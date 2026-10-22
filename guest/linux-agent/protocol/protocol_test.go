package protocol

import (
	"bytes"
	"encoding/hex"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func strp(s string) *string { return &s }

func sampleMessages() []Message {
	return []Message{
		Hello{ProtocolVersion: 1, Role: "guest", OS: "Linux Debian 13 (6.12.0)", AgentVersion: "0.1.0",
			Capabilities: []string{"coherence", "clipboard", "input"}},
		WindowList{Windows: []WindowInfo{
			{ID: 0x1a00003, PID: 1234, AppName: "Firefox", Title: "Mozilla Firefox — ü",
				Frame: Rect{X: 10, Y: 20.5, Width: 800, Height: 600}, Layer: 0, Kind: KindNormal, IsFocused: true},
			{ID: 7, PID: 0, AppName: "", BundleID: strp("org.example"), Title: "",
				Frame: Rect{X: -5, Y: 0, Width: 1, Height: 1}, Layer: 101, Kind: KindMenu},
		}},
		Frame{SurfaceWidth: 4, SurfaceHeight: 3, X: 1, Y: 1, Width: 2, Height: 2, Encoding: EncodingRaw,
			Data: bytes.Repeat([]byte{1, 2, 3, 255}, 4)},
		DisplayInfo{WidthPoints: 1920, HeightPoints: 1080, Scale: 1, MenuBarHeight: 0},
		Pointer{Kind: PointerScroll, Button: ButtonRight, ClickCount: 2, PreciseScroll: true, X: 1.5, Y: -2.25,
			ScrollDX: 0.5, ScrollDY: -12, Modifiers: 1 << 20},
		Key{KeyCode: 0x24, Down: true, Modifiers: 1 << 17, Text: "é😀"},
		Key{KeyCode: 0, Down: false},
		WindowAction{WindowID: 42, Action: ActionResize, Frame: &Rect{X: 1, Y: 2, Width: 3, Height: 4}},
		WindowAction{WindowID: 42, Action: ActionClose},
		SetCoherence{Enabled: true, MaxFPS: 60},
		Clipboard{Items: []ClipboardItem{{Type: UTIPlainText, Data: []byte("hello")}, {Type: UTIPNG, Data: []byte{0x89, 'P', 'N', 'G'}}}},
		Ping(0xdeadbeefcafef00d),
		Pong(1),
		Log("hello log ✓"),
		FileDrop{Files: []string{"batch/a b.txt", "batch/dir"}, X: f64p(12.5), Y: f64p(3)},
		FileDrop{Files: []string{"x"}},
		MountShares{Server: "10.0.2.4", Username: "alice", Password: "secret", Shares: []MountShare{
			{Name: "Docs", Letter: "Z"}, {Name: "VitrineTransfer", ReadOnly: true}}},
		AppIconRequest{Key: "org.mozilla.firefox"},
		AppIcon{Key: "x", PNG: []byte{0x89, 'P', 'N', 'G'}},
		AppCatalogRequest{IconSize: 128},
		AppCatalog{Apps: []CatalogApp{{ID: "/usr/share/applications/a.desktop", Key: strp("firefox"), Name: "Firefox", PNG: []byte{1}},
			{ID: "b", Name: "B"}}},
		LaunchApp{ID: "a.desktop"},
		TimeSync{UnixMillis: 1792231470123},
		GuestNetwork{Interfaces: []NetInterface{{Name: "enp0s1", MAC: "be:47:a9:b7:36:2c",
			IPv4: []string{"192.168.64.5"}, IPv6: []string{"fd00::5"}}}},
		GuestStats{CPUPercent: f64p(12.5), MemoryTotal: u64p(4 << 30), MemoryUsed: u64p(1 << 30), UptimeSeconds: u64p(90)},
		CameraStart{Width: 1280, Height: 720, FPS: 30},
		CameraFrame{Width: 2, Height: 2, Data: []byte{1, 2, 3, 4, 5, 6, 7, 8}},
		CameraStop{},
		CameraStatus{Ready: true, Device: "/dev/video0"},
		CameraStatus{Error: "no", Installable: boolp(false)},
		BluetoothStart{},
		BluetoothHCI{1, 0x03, 0x0c, 0},
		BluetoothStop{},
		BluetoothStatus{Ready: true, Device: "hci0"},
	}
}

func u64p(v uint64) *uint64 { return &v }

func boolp(v bool) *bool { return &v }

func f64p(v float64) *float64 { return &v }

func TestRoundTripAllTypes(t *testing.T) {
	seen := map[MessageType]bool{}
	for _, m := range sampleMessages() {
		b, err := Encode(m)
		if err != nil {
			t.Fatalf("encode %T: %v", m, err)
		}
		var d Deframer
		d.Append(b)
		got, err := d.Next()
		if err != nil {
			t.Fatalf("decode %T: %v", m, err)
		}
		if !reflect.DeepEqual(got, m) {
			t.Errorf("round trip %T:\n got %#v\nwant %#v", m, got, m)
		}
		if d.Buffered() != 0 {
			t.Errorf("%T: %d bytes left over", m, d.Buffered())
		}
		seen[m.Type()] = true
	}
	for _, typ := range []MessageType{TypeHello, TypeWindowList, TypeFrame, TypeDisplayInfo, TypePointer, TypeKey,
		TypeWindowAction, TypeSetCoherence, TypeClipboard, TypePing, TypePong, TypeLog, TypeFileDrop, TypeMountShares,
		TypeAppIconReq, TypeAppIcon, TypeAppCatReq, TypeAppCatalog, TypeLaunchApp, TypeTimeSync, TypeGuestNetwork, TypeGuestStats, TypeCameraStart, TypeCameraFrame, TypeCameraStop, TypeCameraStatus} {
		if !seen[typ] {
			t.Errorf("type 0x%02x not covered", typ)
		}
	}
}

// mustHex decodes whitespace-separated hex, ignoring `//` comments.
func mustHex(s string) []byte {
	var clean []string
	for _, line := range strings.Split(s, "\n") {
		if i := strings.Index(line, "//"); i >= 0 {
			line = line[:i]
		}
		clean = append(clean, strings.Fields(line)...)
	}
	b, err := hex.DecodeString(strings.Join(clean, ""))
	if err != nil {
		panic(err)
	}
	return b
}

// Golden bytes derived by hand from Protocol.swift's AgentCodec.encode.
func TestGoldenPointer(t *testing.T) {
	m := Pointer{Kind: PointerDown, Button: ButtonRight, ClickCount: 2, PreciseScroll: true,
		X: 1.5, Y: -2, ScrollDX: 0, ScrollDY: 10, Modifiers: 0x0000_0000_0010_0000}
	want := mustHex(`
		1d000000 10          // length 29 = 1 + 28, type pointer
		01 01 02 01          // kind down, button right, clickCount 2, preciseScroll
		0000c03f             // x = 1.5
		000000c0             // y = -2
		00000000             // scrollDX = 0
		00002041             // scrollDY = 10
		0000100000000000     // modifiers (command)
	`)
	got, _ := Encode(m)
	if !bytes.Equal(got, want) {
		t.Fatalf("pointer bytes\n got %x\nwant %x", got, want)
	}
}

func TestGoldenFrame(t *testing.T) {
	m := Frame{SurfaceWidth: 1920, SurfaceHeight: 1080, X: 16, Y: 32, Width: 1, Height: 2, Encoding: EncodingRaw,
		Data: []byte{0x10, 0x20, 0x30, 0xff, 0x11, 0x21, 0x31, 0xff}}
	want := mustHex(`
		22000000 03          // length 34 = 1 + 25 + 8, type frame
		80070000 38040000    // surface 1920x1080
		10000000 20000000    // x 16, y 32
		01000000 02000000    // width 1, height 2
		00                   // raw
		102030ff 112131ff    // BGRA pixels
	`)
	got, _ := Encode(m)
	if !bytes.Equal(got, want) {
		t.Fatalf("frame bytes\n got %x\nwant %x", got, want)
	}
	head, body, _ := EncodeParts(m)
	if !bytes.Equal(append(head, body...), want) || len(head) != 5+FrameHeaderSize {
		t.Fatalf("EncodeParts mismatch")
	}
}

func TestGoldenKeyPingLog(t *testing.T) {
	cases := []struct {
		m    Message
		want string
	}{
		{Key{KeyCode: 0x7e, Down: true, Modifiers: 0x20000, Text: "A"},
			"0d000000 11 7e00 01 0000020000000000 41"},
		{Ping(0x0102030405060708), "09000000 30 0807060504030201"},
		{Pong(0x0102030405060708), "09000000 31 0807060504030201"},
		{Log("hi"), "03000000 40 6869"},
	}
	for _, c := range cases {
		got, _ := Encode(c.m)
		if want := mustHex(c.want); !bytes.Equal(got, want) {
			t.Errorf("%T\n got %x\nwant %x", c.m, got, want)
		}
	}
}

// JSON payloads must use Swift's key names; field order matches .sortedKeys.
// Every expected string here is verbatim output of Swift's AgentCodec.encode
// (Protocol.swift compiled with swiftc), as are the binary goldens above.
func TestGoldenJSON(t *testing.T) {
	cases := []struct {
		m    Message
		want string
	}{
		{Hello{ProtocolVersion: 1, Role: "guest", OS: "Linux", AgentVersion: "0.1.0", Capabilities: []string{"coherence", "clipboard", "input"}},
			`{"agentVersion":"0.1.0","capabilities":["coherence","clipboard","input"],"os":"Linux","protocolVersion":1,"role":"guest"}`},
		{DisplayInfo{WidthPoints: 1920, HeightPoints: 1080, Scale: 1},
			`{"heightPoints":1080,"menuBarHeight":0,"scale":1,"widthPoints":1920}`},
		{WindowList{Windows: []WindowInfo{{ID: 5, PID: 9, AppName: "XTerm", Title: "t",
			Frame: Rect{X: 1, Y: 2, Width: 3.5, Height: 4}, Kind: KindPanel}}},
			`{"windows":[{"appName":"XTerm","frame":{"height":4,"width":3.5,"x":1,"y":2},"id":5,"isFocused":false,"kind":"panel","layer":0,"pid":9,"title":"t"}]}`},
		{WindowList{}, `{"windows":[]}`},
		{Clipboard{Items: []ClipboardItem{{Type: UTIPlainText, Data: []byte("hi")}}},
			`{"items":[{"data":"aGk=","type":"public.utf8-plain-text"}]}`},
		{Clipboard{Items: []ClipboardItem{{Type: UTIPlainText}}}, `{"items":[{"data":"","type":"public.utf8-plain-text"}]}`},
		{SetCoherence{Enabled: true, MaxFPS: 30}, `{"enabled":true,"maxFPS":30}`},
		{WindowAction{WindowID: 3, Action: ActionMove, Frame: &Rect{X: 1, Y: 2, Width: 3, Height: 4}},
			`{"action":"move","frame":{"height":4,"width":3,"x":1,"y":2},"windowID":3}`},
		{MountShares{Server: "10.0.2.4", Username: "alice", Password: "pw", Shares: []MountShare{
			{Name: "Docs", Letter: "Z"}, {Name: "VitrineTransfer", ReadOnly: true}}},
			`{"password":"pw","server":"10.0.2.4","shares":[{"letter":"Z","name":"Docs","readOnly":false},{"name":"VitrineTransfer","readOnly":true}],"username":"alice"}`},
		{FileDrop{Files: []string{"x"}, X: f64p(10.5), Y: f64p(2)}, `{"files":["x"],"x":10.5,"y":2}`},
		{FileDrop{}, `{"files":[]}`},
		{AppIconRequest{Key: "org.mozilla.firefox"}, `{"key":"org.mozilla.firefox"}`},
		{AppCatalogRequest{IconSize: 64}, `{"iconSize":64}`},
		{AppCatalog{Apps: []CatalogApp{{ID: "a", Key: strp("k"), Name: "A", PNG: []byte{1, 2}}, {ID: "b", Name: "B"}}},
			`{"apps":[{"id":"a","key":"k","name":"A","png":"AQI="},{"id":"b","name":"B"}]}`},
		{LaunchApp{ID: "a"}, `{"id":"a"}`},
		{AppIcon{Key: "k"}, `{"key":"k","png":""}`},
	}
	for _, c := range cases {
		got, err := Encode(c.m)
		if err != nil {
			t.Fatal(err)
		}
		if string(got[5:]) != c.want {
			t.Errorf("%T\n got %s\nwant %s", c.m, got[5:], c.want)
		}
		if int(got[4]) != int(c.m.Type()) {
			t.Errorf("%T: type byte %x", c.m, got[4])
		}
	}
}

// Decoding JSON exactly as Swift's JSONEncoder emits it (escaped slashes,
// missing optional keys, fractional numbers).
func TestDecodeSwiftJSON(t *testing.T) {
	m, err := Decode(uint8(TypeWindowList), []byte(`{"windows":[{"appName":"A","bundleID":null,"frame":{"height":1,"width":1,"x":0,"y":0},"id":1,"isFocused":true,"kind":"menuBar","layer":24,"pid":1,"title":""}]}`))
	if err != nil || m.(WindowList).Windows[0].BundleID != nil || m.(WindowList).Windows[0].Kind != KindMenuBar {
		t.Fatalf("got %#v %v", m, err)
	}
	m, err = Decode(uint8(TypeWindowAction), []byte(`{"action":"focus","windowID":77}`))
	if err != nil || m.(WindowAction).Frame != nil || m.(WindowAction).WindowID != 77 {
		t.Fatalf("got %#v %v", m, err)
	}
	m, err = Decode(uint8(TypeClipboard), []byte(`{"items":[{"data":"aGVsbG8=","type":"public.utf8-plain-text"},{"data":"","type":"public\/png"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	c := m.(Clipboard)
	if string(c.Items[0].Data) != "hello" || c.Items[1].Type != "public/png" {
		t.Fatalf("got %#v", c)
	}
	// Swift escapes "/" in strings.
	m, err = Decode(uint8(TypeMountShares), []byte(`{"password":"p\/w","server":"10.0.2.4","shares":[{"letter":"Z","name":"Docs","readOnly":false},{"name":"VitrineTransfer","readOnly":true}],"username":"alice"}`))
	if err != nil || m.(MountShares).Password != "p/w" || m.(MountShares).Shares[1].Letter != "" || !m.(MountShares).Shares[1].ReadOnly {
		t.Fatalf("got %#v %v", m, err)
	}
	m, err = Decode(uint8(TypeFileDrop), []byte(`{"files":["b\/a.txt"]}`))
	if err != nil || m.(FileDrop).Files[0] != "b/a.txt" || m.(FileDrop).X != nil {
		t.Fatalf("got %#v %v", m, err)
	}
	m, err = Decode(uint8(TypeHello), []byte(`{"agentVersion":"1.0","capabilities":[],"os":"macOS 27.0","protocolVersion":1,"role":"host"}`))
	if err != nil || m.(Hello).Role != "host" || m.(Hello).Token != "" {
		t.Fatalf("got %#v %v", m, err)
	}
	m, err = Decode(uint8(TypeHello), []byte(`{"agentVersion":"1.0","capabilities":[],"os":"macOS 27.0","protocolVersion":1,"role":"host","token":"ab12"}`))
	if err != nil || m.(Hello).Token != "ab12" {
		t.Fatalf("got %#v %v", m, err)
	}
}

func TestDecodeErrors(t *testing.T) {
	if _, err := Decode(0x99, nil); !errors.As(err, new(UnknownTypeError)) {
		t.Errorf("unknown type: %v", err)
	}
	if _, err := Decode(uint8(TypePing), []byte{1, 2, 3}); !errors.Is(err, ErrTruncated) {
		t.Errorf("short ping: %v", err)
	}
	if _, err := Decode(uint8(TypePointer), make([]byte, 27)); !errors.Is(err, ErrTruncated) {
		t.Errorf("short pointer: %v", err)
	}
	bad := Frame{SurfaceWidth: 2, SurfaceHeight: 2, X: 1, Y: 0, Width: 2, Height: 1, Data: make([]byte, 8)}
	b, _ := Encode(bad)
	if _, err := Decode(b[4], b[5:]); !errors.As(err, new(MalformedError)) {
		t.Errorf("frame outside surface: %v", err)
	}
	short := Frame{SurfaceWidth: 2, SurfaceHeight: 2, Width: 2, Height: 1, Data: make([]byte, 7)}
	b, _ = Encode(short)
	if _, err := Decode(b[4], b[5:]); !errors.As(err, new(MalformedError)) {
		t.Errorf("raw frame size: %v", err)
	}
	ptr, _ := Encode(Pointer{Kind: 9})
	if _, err := Decode(ptr[4], ptr[5:]); !errors.As(err, new(MalformedError)) {
		t.Errorf("bad pointer kind: %v", err)
	}
	if _, err := Encode(Frame{SurfaceWidth: 4096, SurfaceHeight: 4096, Width: 4096, Height: 4096,
		Data: make([]byte, 4096*4096*4)}); !errors.As(err, new(TooLargeError)) {
		t.Errorf("too large: %v", err)
	}
}

func TestFingerprintOrderIndependent(t *testing.T) {
	a := Clipboard{Items: []ClipboardItem{{Type: UTIPlainText, Data: []byte("x")}, {Type: UTIPNG, Data: []byte("y")}}}
	b := Clipboard{Items: []ClipboardItem{a.Items[1], a.Items[0]}}
	c := Clipboard{Items: []ClipboardItem{{Type: UTIPlainText, Data: []byte("xy")}}}
	if a.Fingerprint() != b.Fingerprint() {
		t.Error("fingerprint depends on order")
	}
	if a.Fingerprint() == c.Fingerprint() {
		t.Error("fingerprint collision")
	}
}
