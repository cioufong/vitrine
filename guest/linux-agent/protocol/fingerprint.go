package protocol

import (
	"crypto/sha256"
	"encoding/binary"
	"sort"
)

// Fingerprint is an order-independent digest of clipboard contents, used to
// suppress echo loops between host and guest (like ClipboardContent.fingerprint
// in Swift; the values are never compared across the wire).
func (c Clipboard) Fingerprint() [32]byte {
	items := append([]ClipboardItem(nil), c.Items...)
	sort.SliceStable(items, func(i, j int) bool { return items[i].Type < items[j].Type })
	h := sha256.New()
	var n [8]byte
	for _, it := range items {
		binary.LittleEndian.PutUint64(n[:], uint64(len(it.Type)))
		h.Write(n[:])
		h.Write([]byte(it.Type))
		binary.LittleEndian.PutUint64(n[:], uint64(len(it.Data)))
		h.Write(n[:])
		h.Write(it.Data)
	}
	var out [32]byte
	copy(out[:], h.Sum(nil))
	return out
}
