// Package protocol implements Vitrine's host ⇄ guest agent wire protocol.
//
// It mirrors Sources/VitrineAgentProtocol/Protocol.swift byte for byte:
//
//	frame = u32 LE length (type byte + payload) · u8 type · payload
//
// Control messages carry JSON payloads (Swift Codable, Data fields as base64);
// hot-path messages (frames, input, ping/pong) are packed little-endian binary.
package protocol

const (
	// Version is the protocol version announced in Hello.
	Version = 1
	// VsockPort is the vsock port the guest agent listens on ("SQ").
	VsockPort = 0x5153
	// MaxMessageSize bounds one message (type byte + payload).
	MaxMessageSize = 64 << 20
	// MaxCameraDimension bounds a camera frame edge (Swift: CameraFrame.maxDimension).
	MaxCameraDimension = 4096
	// MaxHCIPacket bounds one BluetoothHCI packet (Swift: BluetoothHCI.maxSize).
	MaxHCIPacket = 4096
	// MaxSurfaceDimension bounds a frame's surface edge (Swift:
	// AgentProtocol.maxSurfaceDimension).
	MaxSurfaceDimension = 8192
)

// MessageType is the one-byte discriminator following the length prefix.
type MessageType uint8

const (
	TypeHello        MessageType = 0x01
	TypeWindowList   MessageType = 0x02
	TypeFrame        MessageType = 0x03
	TypeDisplayInfo  MessageType = 0x04
	TypePointer      MessageType = 0x10
	TypeKey          MessageType = 0x11
	TypeWindowAction MessageType = 0x12
	TypeSetCoherence MessageType = 0x13
	TypeClipboard    MessageType = 0x20
	TypeFileDrop     MessageType = 0x21
	TypeMountShares  MessageType = 0x22
	TypeAppIconReq   MessageType = 0x24
	TypeAppIcon      MessageType = 0x25
	TypeAppCatReq    MessageType = 0x26
	TypeAppCatalog   MessageType = 0x27
	TypeLaunchApp    MessageType = 0x28
	TypeTimeSync     MessageType = 0x29
	TypeGuestNetwork MessageType = 0x2A
	TypeGuestStats   MessageType = 0x2B
	TypeCameraStart  MessageType = 0x2C
	TypeCameraFrame  MessageType = 0x2D
	TypeCameraStop   MessageType = 0x2E
	TypeCameraStatus MessageType = 0x2F
	TypePing         MessageType = 0x30
	TypePong         MessageType = 0x31
	TypeBTStart      MessageType = 0x32
	TypeBTHCI        MessageType = 0x33
	TypeBTStop       MessageType = 0x34
	TypeBTStatus     MessageType = 0x35
	// TypeRequestPermissions asks a macOS agent to prompt for its permissions; this agent never
	// gets it (it doesn't offer the "permissions" capability).
	TypeRequestPermissions MessageType = 0x36
	TypeLog                MessageType = 0x40
)

// Message is any protocol message.
type Message interface {
	Type() MessageType
}

// JSON field order below is alphabetical so encoded output matches Swift's
// JSONEncoder(.sortedKeys) key order (not required for decoding, but keeps
// payloads byte-identical in the common case).

// Hello is exchanged by both sides right after connecting.
type Hello struct {
	AgentVersion    string   `json:"agentVersion"`
	Capabilities    []string `json:"capabilities"`
	OS              string   `json:"os"`
	ProtocolVersion int      `json:"protocolVersion"`
	Role            string   `json:"role"`
	// Token is the per-VM secret a host presents to agents reachable over TCP
	// (Windows on QEMU), which read it from SMBIOS OEM strings. Omitted when empty.
	Token string `json:"token,omitempty"`
}

// DisplayInfo describes guest display geometry. Window frames are in guest
// global points with a top-left origin; pixels = points * Scale.
type DisplayInfo struct {
	HeightPoints  float64 `json:"heightPoints"`
	MenuBarHeight float64 `json:"menuBarHeight"`
	Scale         float64 `json:"scale"`
	WidthPoints   float64 `json:"widthPoints"`
}

// Rect is a rectangle in guest points (top-left origin).
type Rect struct {
	Height float64 `json:"height"`
	Width  float64 `json:"width"`
	X      float64 `json:"x"`
	Y      float64 `json:"y"`
}

// Window kinds.
const (
	KindNormal  = "normal"
	KindPanel   = "panel"
	KindMenu    = "menu"
	KindMenuBar = "menuBar"
)

// WindowInfo describes one guest window.
type WindowInfo struct {
	AppName   string  `json:"appName"`
	BundleID  *string `json:"bundleID,omitempty"` // omitted when nil, exactly like Swift's synthesized Codable
	Frame     Rect    `json:"frame"`
	ID        uint32  `json:"id"`
	IsFocused bool    `json:"isFocused"`
	Kind      string  `json:"kind"`
	Layer     int     `json:"layer"`
	PID       int32   `json:"pid"`
	Title     string  `json:"title"`
}

// WindowList lists windows ordered front-to-back.
type WindowList struct {
	Windows []WindowInfo `json:"windows"`
}

// Frame encodings.
const (
	EncodingRaw uint8 = 0
	EncodingLZ4 uint8 = 1
)

// Frame is a dirty rectangle of the guest framebuffer. Pixels are BGRA8
// premultiplied, tightly packed (stride = Width*4) once decoded.
type Frame struct {
	SurfaceWidth, SurfaceHeight uint32
	X, Y, Width, Height         uint32
	Encoding                    uint8
	Data                        []byte
}

// Pointer kinds and buttons.
const (
	PointerMove   uint8 = 0
	PointerDown   uint8 = 1
	PointerUp     uint8 = 2
	PointerDrag   uint8 = 3
	PointerScroll uint8 = 4

	ButtonLeft  uint8 = 0
	ButtonRight uint8 = 1
	ButtonOther uint8 = 2
)

// Pointer is a mouse event in guest global points.
type Pointer struct {
	Kind          uint8
	Button        uint8
	ClickCount    uint8
	PreciseScroll bool
	X, Y          float32
	ScrollDX      float32
	ScrollDY      float32
	Modifiers     uint64 // CGEventFlags / NSEvent.ModifierFlags raw value
}

// Key is a keyboard event carrying a macOS virtual key code (kVK_*).
type Key struct {
	KeyCode   uint16
	Down      bool
	Modifiers uint64
	Text      string // characters the host produced (may be empty)
}

// Window actions.
const (
	ActionFocus    = "focus"
	ActionClose    = "close"
	ActionMinimize = "minimize"
	ActionMove     = "move"
	ActionResize   = "resize"
	ActionZoom     = "zoom"
)

// WindowAction asks the guest to manipulate one of its windows.
type WindowAction struct {
	Action   string `json:"action"`
	Frame    *Rect  `json:"frame,omitempty"`
	WindowID uint32 `json:"windowID"`
}

// SetCoherence (CoherenceRequest in Swift) starts or stops streaming.
type SetCoherence struct {
	Enabled bool `json:"enabled"`
	MaxFPS  int  `json:"maxFPS"`
}

// Clipboard item UTIs this agent understands.
const (
	UTIPlainText = "public.utf8-plain-text"
	UTIPNG       = "public.png"
)

// ClipboardItem is one representation; Data is base64 in JSON.
type ClipboardItem struct {
	Data []byte `json:"data"`
	Type string `json:"type"`
}

// Clipboard (ClipboardContent in Swift) is the full clipboard contents.
type Clipboard struct {
	Items []ClipboardItem `json:"items"`
}

// FileDrop lists files the host placed in its transfer folder for the guest to
// take (paths relative to that folder). X/Y: drop point in guest points, if any.
type FileDrop struct {
	Files []string `json:"files"`
	X     *float64 `json:"x,omitempty"`
	Y     *float64 `json:"y,omitempty"`
}

// MountShare is one SMB share to map. Letter is a drive letter ("Z") or empty
// for shares reachable by UNC path only.
type MountShare struct {
	Letter   string `json:"letter,omitempty"`
	Name     string `json:"name"`
	ReadOnly bool   `json:"readOnly"`
}

// MountShares lists the host's SMB shares and the credentials for this VM run.
type MountShares struct {
	Password string       `json:"password"`
	Server   string       `json:"server"`
	Shares   []MountShare `json:"shares"`
	Username string       `json:"username"`
}

// AppIconRequest asks for the icon of the app whose windows carry Key
// (WindowInfo.BundleID, or AppName when that is nil).
type AppIconRequest struct {
	Key string `json:"key"`
}

// AppIcon is an app's icon as PNG (empty when there is none).
type AppIcon struct {
	Key string `json:"key"`
	PNG []byte `json:"png"`
}

// AppCatalogRequest asks for the launchable apps; IconSize 0 = no icons.
type AppCatalogRequest struct {
	IconSize int `json:"iconSize"`
}

// CatalogApp is one launchable app. ID is opaque to the host.
type CatalogApp struct {
	ID   string  `json:"id"`
	Key  *string `json:"key,omitempty"`
	Name string  `json:"name"`
	PNG  []byte  `json:"png,omitempty"`
}

// AppCatalog lists launchable apps.
type AppCatalog struct {
	Apps []CatalogApp `json:"apps"`
}

// LaunchApp starts an app from the catalog.
type LaunchApp struct {
	ID string `json:"id"`
}

// TimeSync carries the host clock (ms since the Unix epoch, UTC).
type TimeSync struct {
	TimeZone        *string `json:"timeZone,omitempty"` // IANA, e.g. "Asia/Taipei"
	UnixMillis      int64   `json:"unixMillis"`
	WindowsTimeZone *string `json:"windowsTimeZone,omitempty"` // e.g. "Taipei Standard Time"
}

// GuestNetwork lists the guest's interfaces and addresses. Sent when the host's
// Hello lists "network", and again whenever it changes.
type GuestNetwork struct {
	Interfaces []NetInterface `json:"interfaces"`
}

// NetInterface is one guest network interface.
type NetInterface struct {
	IPv4 []string `json:"ipv4"`
	IPv6 []string `json:"ipv6"`
	MAC  string   `json:"mac"` // lowercase, colon-separated
	Name string   `json:"name"`
}

// GuestStats is how busy the guest is, sent every few seconds when the host's
// Hello lists "stats". Byte counts; nil where the guest can't tell.
type GuestStats struct {
	CPUPercent    *float64 `json:"cpuPercent,omitempty"` // all CPUs, 0-100
	DiskTotal     *uint64  `json:"diskTotal,omitempty"`
	DiskUsed      *uint64  `json:"diskUsed,omitempty"`
	MemoryTotal   *uint64  `json:"memoryTotal,omitempty"`
	MemoryUsed    *uint64  `json:"memoryUsed,omitempty"`
	OSName        *string  `json:"osName,omitempty"`
	UptimeSeconds *uint64  `json:"uptimeSeconds,omitempty"`
}

// CameraStart tells the guest the host's camera is being shared; CameraFrames
// of this size follow. Sent only to agents whose Hello lists "camera".
type CameraStart struct {
	FPS    int `json:"fps"`
	Height int `json:"height"`
	Width  int `json:"width"`
}

// CameraFrame is one camera image, packed YUYV 4:2:2 (Width*Height*2 bytes).
// Binary on the wire: u32 width, u32 height, pixels.
type CameraFrame struct {
	Width, Height uint32
	Data          []byte
}

// CameraStop ends the camera stream.
type CameraStop struct{}

// CameraStatus answers CameraStart: whether the guest's virtual camera took the stream.
type CameraStatus struct {
	Device string `json:"device,omitempty"` // e.g. /dev/video0
	Error  string `json:"error,omitempty"`
	// Installable says whether the host's "install camera support" would fix
	// Error; omitted means it would.
	Installable *bool `json:"installable,omitempty"`
	Ready       bool  `json:"ready"`
}

// BluetoothStart asks the guest for a Bluetooth controller that the host
// emulates (the Mac's Bluetooth LE). Sent only to agents whose Hello lists
// "bluetooth".
type BluetoothStart struct{}

// BluetoothHCI is one HCI packet in UART (H4) framing, both directions: a
// packet-type byte (1 command, 2 ACL data, 4 event) followed by the packet.
type BluetoothHCI []byte

// BluetoothStop removes the controller.
type BluetoothStop struct{}

// BluetoothStatus answers BluetoothStart, and reports a controller that went away.
type BluetoothStatus struct {
	Device      string `json:"device,omitempty"` // e.g. hci0
	Error       string `json:"error,omitempty"`
	Installable *bool  `json:"installable,omitempty"` // as in CameraStatus
	Ready       bool   `json:"ready"`
}

// Ping / Pong carry an opaque u64.
type (
	Ping uint64
	Pong uint64
	// Log is free-form UTF-8 diagnostic text.
	Log string
)

func (Hello) Type() MessageType             { return TypeHello }
func (WindowList) Type() MessageType        { return TypeWindowList }
func (Frame) Type() MessageType             { return TypeFrame }
func (DisplayInfo) Type() MessageType       { return TypeDisplayInfo }
func (Pointer) Type() MessageType           { return TypePointer }
func (Key) Type() MessageType               { return TypeKey }
func (WindowAction) Type() MessageType      { return TypeWindowAction }
func (SetCoherence) Type() MessageType      { return TypeSetCoherence }
func (Clipboard) Type() MessageType         { return TypeClipboard }
func (FileDrop) Type() MessageType          { return TypeFileDrop }
func (MountShares) Type() MessageType       { return TypeMountShares }
func (AppIconRequest) Type() MessageType    { return TypeAppIconReq }
func (AppIcon) Type() MessageType           { return TypeAppIcon }
func (AppCatalogRequest) Type() MessageType { return TypeAppCatReq }
func (AppCatalog) Type() MessageType        { return TypeAppCatalog }
func (LaunchApp) Type() MessageType         { return TypeLaunchApp }
func (TimeSync) Type() MessageType          { return TypeTimeSync }
func (GuestNetwork) Type() MessageType      { return TypeGuestNetwork }
func (GuestStats) Type() MessageType        { return TypeGuestStats }
func (CameraStart) Type() MessageType       { return TypeCameraStart }
func (CameraFrame) Type() MessageType       { return TypeCameraFrame }
func (CameraStop) Type() MessageType        { return TypeCameraStop }
func (CameraStatus) Type() MessageType      { return TypeCameraStatus }
func (BluetoothStart) Type() MessageType    { return TypeBTStart }
func (BluetoothHCI) Type() MessageType      { return TypeBTHCI }
func (BluetoothStop) Type() MessageType     { return TypeBTStop }
func (BluetoothStatus) Type() MessageType   { return TypeBTStatus }
func (Ping) Type() MessageType              { return TypePing }
func (Pong) Type() MessageType              { return TypePong }
func (Log) Type() MessageType               { return TypeLog }
