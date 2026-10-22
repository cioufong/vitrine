//go:build windows

package win

import (
	"fmt"
	"unsafe"
)

var procGetSystemFirmwareTable = kernel32.NewProc("GetSystemFirmwareTable")

// rsmb is the 'RSMB' firmware table provider (raw SMBIOS).
const rsmb = 'R'<<24 | 'S'<<16 | 'M'<<8 | 'B'

// AgentToken returns the per-VM token the host put in the SMBIOS OEM strings,
// or "" when there is none (an older host, or not QEMU).
func AgentToken() (string, error) {
	n, _, err := procGetSystemFirmwareTable.Call(rsmb, 0, 0, 0)
	if n == 0 {
		return "", fmt.Errorf("GetSystemFirmwareTable: %v", err)
	}
	buf := make([]byte, n)
	m, _, err := procGetSystemFirmwareTable.Call(rsmb, 0, uintptr(unsafe.Pointer(&buf[0])), n)
	if m == 0 || m > n {
		return "", fmt.Errorf("GetSystemFirmwareTable: %v", err)
	}
	tok, _ := tokenFromRawSMBIOS(buf[:m])
	return tok, nil
}
