//go:build windows

package win

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/png"
	"os/exec"
	"runtime"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

var (
	shell32                         = windows.NewLazySystemDLL("shell32.dll")
	ole32                           = windows.NewLazySystemDLL("ole32.dll")
	procSHCreateItemFromParsingName = shell32.NewProc("SHCreateItemFromParsingName")
	procCoInitializeEx              = ole32.NewProc("CoInitializeEx")
	procCoUninitialize              = ole32.NewProc("CoUninitialize")
	procGetDIBits                   = gdi32.NewProc("GetDIBits")

	// IID_IShellItemImageFactory
	iidShellItemImageFactory = windows.GUID{Data1: 0xbcc18b79, Data2: 0xba16, Data3: 0x442f,
		Data4: [8]byte{0x80, 0xc4, 0x8a, 0x59, 0xc3, 0x0c, 0x46, 0x3b}}
)

const (
	siigbfBiggerSizeOK = 0x1
	siigbfIconOnly     = 0x4
	createNoWindow     = 0x08000000
)

// startApp is one row of Get-StartApps.
type startApp struct {
	Name  string `json:"Name"`
	AppID string `json:"AppID"`
}

// AppCatalog implements agent.AppProvider from the Start menu's app list
// (desktop and Store apps alike).
func (b *Backend) AppCatalog(iconSize int) (protocol.AppCatalog, error) {
	apps, err := startApps()
	if err != nil {
		return protocol.AppCatalog{}, err
	}
	var cat protocol.AppCatalog
	for _, a := range apps {
		if a.Name == "" || a.AppID == "" || strings.Contains(strings.ToLower(a.Name), "uninstall") {
			continue
		}
		app := protocol.CatalogApp{ID: a.AppID, Name: a.Name}
		if exe := knownFolderAppPath(a.AppID); exe != "" {
			app.Key = &exe
		}
		if iconSize > 0 {
			app.PNG, _ = shellImagePNG(`shell:AppsFolder\`+a.AppID, iconSize)
		}
		cat.Apps = append(cat.Apps, app)
	}
	return cat, nil
}

// AppIcon implements agent.AppProvider: key is a window's executable path. Store
// apps use their Start menu entry, whose icon is the tile users know.
func (b *Backend) AppIcon(key string) ([]byte, error) {
	b.winMu.Lock()
	aumid := ""
	for _, e := range b.exes {
		if strings.EqualFold(e.path, key) && e.aumid != "" {
			aumid = e.aumid
			break
		}
	}
	b.winMu.Unlock()
	if aumid != "" {
		if png, err := shellImagePNG(`shell:AppsFolder\`+aumid, 256); err == nil {
			return png, nil
		}
	}
	return shellImagePNG(key, 256)
}

// LaunchApp implements agent.AppProvider: id is a Start menu AppID.
func (b *Backend) LaunchApp(id string) error {
	if id == "" || len(id) > 1024 || strings.ContainsAny(id, "\"\r\n\x00") {
		return fmt.Errorf("bad app id %q", id)
	}
	cmd := exec.Command("explorer.exe", `shell:AppsFolder\`+id)
	return cmd.Start()
}

func startApps() ([]startApp, error) {
	cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
		"[Console]::OutputEncoding=[Text.Encoding]::UTF8; Get-StartApps | Select-Object Name,AppID | ConvertTo-Json -Compress")
	// The agent is a GUI app: keep PowerShell from flashing a console window.
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("Get-StartApps: %w", err)
	}
	out = bytes.TrimSpace(bytes.TrimPrefix(out, []byte("\xef\xbb\xbf")))
	if len(out) == 0 {
		return nil, nil
	}
	var apps []startApp
	if out[0] == '{' { // a single app is not wrapped in an array
		var one startApp
		err = json.Unmarshal(out, &one)
		apps = []startApp{one}
	} else {
		err = json.Unmarshal(out, &apps)
	}
	return apps, err
}

// knownFolderAppPath turns a desktop app's AppID ("{known-folder-guid}\rel\app.exe")
// into the executable path its windows report, so Dock icons and launchers match.
func knownFolderAppPath(appID string) string {
	if !strings.HasPrefix(appID, "{") || !strings.HasSuffix(strings.ToLower(appID), ".exe") {
		return ""
	}
	end := strings.Index(appID, "}")
	if end < 0 {
		return ""
	}
	guid, err := windows.GUIDFromString(appID[:end+1])
	if err != nil {
		return ""
	}
	base, err := windows.KnownFolderPath((*windows.KNOWNFOLDERID)(&guid), 0)
	if err != nil {
		return ""
	}
	return base + appID[end+1:]
}

// shellImagePNG renders the Shell's icon for a parsing name (a file path or
// shell:AppsFolder\<AppID>) at size×size, with alpha, as PNG.
func shellImagePNG(parsingName string, size int) ([]byte, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if hr, _, _ := procCoInitializeEx.Call(0, 0x2 /* COINIT_APARTMENTTHREADED */); int32(hr) >= 0 {
		defer procCoUninitialize.Call()
	}
	name, err := windows.UTF16PtrFromString(parsingName)
	if err != nil {
		return nil, err
	}
	var factory *struct{ vtbl *[4]uintptr } // COM object: IUnknown(3) + GetImage
	hr, _, _ := procSHCreateItemFromParsingName.Call(uintptr(unsafe.Pointer(name)), 0,
		uintptr(unsafe.Pointer(&iidShellItemImageFactory)), uintptr(unsafe.Pointer(&factory)))
	if int32(hr) < 0 || factory == nil {
		return nil, fmt.Errorf("no shell item for %s (0x%x)", parsingName, uint32(hr))
	}
	vtbl := factory.vtbl
	defer syscall.SyscallN(vtbl[2], uintptr(unsafe.Pointer(factory))) // Release
	var hbm uintptr
	sz := uintptr(uint32(size)) | uintptr(uint32(size))<<32 // SIZE {cx, cy} passed by value
	hr, _, _ = syscall.SyscallN(vtbl[3], uintptr(unsafe.Pointer(factory)), sz, siigbfIconOnly|siigbfBiggerSizeOK,
		uintptr(unsafe.Pointer(&hbm)))
	if int32(hr) < 0 || hbm == 0 {
		return nil, fmt.Errorf("GetImage failed (0x%x)", uint32(hr))
	}
	defer procDeleteObject.Call(hbm)
	img, err := hbitmapImage(hbm, size)
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// hbitmapImage reads a 32-bit (premultiplied BGRA) bitmap of size×size.
func hbitmapImage(hbm uintptr, size int) (*image.NRGBA, error) {
	dc, _, _ := procCreateCompatibleDC.Call(0)
	if dc == 0 {
		return nil, errors.New("CreateCompatibleDC failed")
	}
	defer procDeleteDC.Call(dc)
	bmi := bitmapInfoHeader{Size: uint32(unsafe.Sizeof(bitmapInfoHeader{})), Width: int32(size), Height: -int32(size),
		Planes: 1, BitCount: 32, Compression: biRGB}
	pix := make([]byte, size*size*4)
	if n, _, _ := procGetDIBits.Call(dc, hbm, 0, uintptr(size), uintptr(unsafe.Pointer(&pix[0])),
		uintptr(unsafe.Pointer(&bmi)), dibRGBColors); n == 0 {
		return nil, errors.New("GetDIBits failed")
	}
	return premultipliedBGRAToNRGBA(pix, size, size), nil
}
