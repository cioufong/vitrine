package win

import (
	"bytes"
	"encoding/binary"
	"strings"
)

// Platform-independent SMBIOS parsing (tested on any OS).

// tokenPrefix marks the OEM string carrying the per-VM agent token, set by the
// host with QEMU's -smbios type=11,value=vitrine.token=<hex>.
const tokenPrefix = "vitrine.token="

// tokenFromRawSMBIOS finds the agent token among the OEM strings (structure
// type 11) of a table returned by GetSystemFirmwareTable('RSMB'): a
// RawSMBIOSData header (calling method, major, minor, DMI revision, u32 LE
// length) followed by the structures. Each structure is type, length, u16
// handle, the rest of its formatted area, then NUL-terminated strings ending
// in a double NUL.
func tokenFromRawSMBIOS(raw []byte) (string, bool) {
	if len(raw) < 8 {
		return "", false
	}
	t := raw[8:]
	if n := binary.LittleEndian.Uint32(raw[4:8]); uint64(n) < uint64(len(t)) {
		t = t[:n]
	}
	for len(t) >= 4 {
		typ, n := t[0], int(t[1])
		if n < 4 || n > len(t) {
			break
		}
		strs := t[n:]
		end := bytes.Index(strs, []byte{0, 0})
		if end < 0 {
			break
		}
		if typ == 11 {
			for _, s := range bytes.Split(strs[:end], []byte{0}) {
				if v, ok := strings.CutPrefix(string(s), tokenPrefix); ok && v != "" {
					return v, true
				}
			}
		}
		if typ == 127 { // end-of-table
			break
		}
		t = strs[end+2:]
	}
	return "", false
}
