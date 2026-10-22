package win

import (
	"encoding/binary"
	"strings"
	"testing"
)

// smbiosStruct builds one structure: formatted area of formatted bytes after
// the 4-byte header, then the string-set.
func smbiosStruct(typ byte, formatted []byte, strs ...string) []byte {
	b := []byte{typ, byte(4 + len(formatted)), 0x34, 0x12}
	b = append(b, formatted...)
	if len(strs) == 0 {
		return append(b, 0, 0)
	}
	for _, s := range strs {
		b = append(append(b, s...), 0)
	}
	return append(b, 0)
}

func rawSMBIOS(structs ...[]byte) []byte {
	var table []byte
	for _, s := range structs {
		table = append(table, s...)
	}
	raw := []byte{0, 3, 0, 0, 0, 0, 0, 0}
	binary.LittleEndian.PutUint32(raw[4:], uint32(len(table)))
	return append(raw, table...)
}

func TestTokenFromRawSMBIOS(t *testing.T) {
	tok := strings.Repeat("ab", 32)
	raw := rawSMBIOS(
		smbiosStruct(0, []byte{1, 2, 0, 0xf0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, "EDK II", "stable"),
		smbiosStruct(1, make([]byte, 23), "QEMU", "vitrine.token=decoy-in-type-1"),
		smbiosStruct(4, make([]byte, 10)), // no strings
		smbiosStruct(11, []byte{2}, "other=1", "vitrine.token="+tok),
		smbiosStruct(127, nil),
	)
	if got, ok := tokenFromRawSMBIOS(raw); !ok || got != tok {
		t.Fatalf("got %q %v", got, ok)
	}

	for name, raw := range map[string][]byte{
		"no type 11":   rawSMBIOS(smbiosStruct(1, make([]byte, 23), "vitrine.token=x"), smbiosStruct(127, nil)),
		"empty value":  rawSMBIOS(smbiosStruct(11, []byte{1}, "vitrine.token=")),
		"after end":    rawSMBIOS(smbiosStruct(127, nil), smbiosStruct(11, []byte{1}, "vitrine.token=x")),
		"short header": {0, 3, 0},
		"truncated":    rawSMBIOS(smbiosStruct(11, []byte{1}, "vitrine.token=x"))[:20],
		"bad length":   rawSMBIOS([]byte{11, 200, 0, 0, 1, 0, 0}),
	} {
		if got, ok := tokenFromRawSMBIOS(raw); ok {
			t.Errorf("%s: found %q", name, got)
		}
	}
}
