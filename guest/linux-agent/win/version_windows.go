//go:build windows

package win

import (
	"fmt"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// fileDescription returns an executable's FileDescription ("Paint" for mspaint.exe), the
// name Explorer and Task Manager show, or "" when it has none.
func fileDescription(path string) string {
	size, err := windows.GetFileVersionInfoSize(path, nil)
	if err != nil || size == 0 {
		return ""
	}
	buf := make([]byte, size)
	if err := windows.GetFileVersionInfo(path, 0, size, unsafe.Pointer(&buf[0])); err != nil {
		return ""
	}
	// First language/code page pair from the translation table.
	var trans unsafe.Pointer
	var transLen uint32
	lang := "040904b0" // en-US, Unicode
	if windows.VerQueryValue(unsafe.Pointer(&buf[0]), `\VarFileInfo\Translation`, unsafe.Pointer(&trans), &transLen) == nil && transLen >= 4 {
		t := (*[2]uint16)(trans)
		lang = fmt.Sprintf("%04x%04x", t[0], t[1])
	}
	var value unsafe.Pointer
	var valueLen uint32
	if windows.VerQueryValue(unsafe.Pointer(&buf[0]), `\StringFileInfo\`+lang+`\FileDescription`,
		unsafe.Pointer(&value), &valueLen) != nil || valueLen == 0 {
		return ""
	}
	return strings.TrimSpace(windows.UTF16PtrToString((*uint16)(value)))
}
