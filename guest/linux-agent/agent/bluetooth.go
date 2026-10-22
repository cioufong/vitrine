package agent

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"time"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// BluetoothSocket is where the guest's Bluetooth bridge (`vitrine-agent
// bluetooth-bridge`, a root service) listens. Each connection to it is one HCI
// controller in the guest's kernel: the bridge first answers "ok hciN" or
// "error <reason>" on a line, then carries the controller's HCI traffic in UART
// (H4) framing both ways, and removes the controller when the connection closes.
const BluetoothSocket = "/run/vitrine/bluetooth.sock"

// dialBluetooth reaches the bridge (replaced in tests).
var dialBluetooth = func() (net.Conn, error) { return net.DialTimeout("unix", BluetoothSocket, 2*time.Second) }

var errNoBluetoothBridge = errors.New("the guest's Bluetooth bridge isn't running (install Bluetooth support from Vitrine)")

// bluetoothStart adds the host's controller to the guest and tells the host
// whether it worked, unless a stop or a newer start has taken gen's place.
func (s *session) bluetoothStart(gen int) {
	yes := true
	c, err := dialBluetooth()
	if err != nil {
		if s.bluetoothCurrent(gen) {
			s.conn.Send(protocol.BluetoothStatus{Error: errNoBluetoothBridge.Error(), Installable: &yes})
		}
		return
	}
	r := bufio.NewReaderSize(c, 8192)
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	line, err := r.ReadString('\n')
	c.SetReadDeadline(time.Time{})
	line = strings.TrimSpace(line)
	dev, ok := strings.CutPrefix(line, "ok ")
	if err != nil || !ok {
		c.Close()
		reason := strings.TrimPrefix(line, "error ")
		if err != nil {
			reason = fmt.Sprintf("no answer from the Bluetooth bridge: %v", err)
		}
		if s.bluetoothCurrent(gen) {
			s.conn.Send(protocol.BluetoothStatus{Error: reason, Installable: &yes})
		}
		return
	}
	s.btMu.Lock()
	stopped := s.btGen != gen
	if !stopped {
		s.bt = c
	}
	s.btMu.Unlock()
	if stopped {
		c.Close()
		return
	}
	s.logf("bluetooth on: %s", dev)
	s.conn.Send(protocol.BluetoothStatus{Ready: true, Device: dev})
	go s.pumpBluetooth(c, r)
}

// pumpBluetooth forwards the guest kernel's HCI packets to the host until the
// bridge connection ends.
func (s *session) pumpBluetooth(c net.Conn, r io.Reader) {
	var err error
	for {
		var p []byte
		if p, err = readH4(r); err != nil {
			break
		}
		if !s.conn.Send(protocol.BluetoothHCI(p)) {
			break
		}
	}
	s.btMu.Lock()
	current := s.bt == c
	if current {
		s.bt = nil
	}
	s.btMu.Unlock()
	c.Close()
	if current {
		s.logf("bluetooth bridge closed: %v", err)
		s.conn.TrySend(protocol.BluetoothStatus{Error: "the guest's Bluetooth controller went away"})
	}
}

// bluetoothHCI hands one packet from the host's controller to the guest kernel.
func (s *session) bluetoothHCI(p protocol.BluetoothHCI) {
	s.btMu.Lock()
	c := s.bt
	s.btMu.Unlock()
	if c != nil {
		c.Write(p)
	}
}

func (s *session) bluetoothCurrent(gen int) bool {
	s.btMu.Lock()
	defer s.btMu.Unlock()
	return s.btGen == gen
}

// closeBluetooth removes the controller, if attached, and returns the new
// generation.
func (s *session) closeBluetooth() int {
	s.btMu.Lock()
	c := s.bt
	s.bt = nil
	s.btGen++
	gen := s.btGen
	s.btMu.Unlock()
	if c != nil {
		c.Close()
		s.logf("bluetooth off")
	}
	return gen
}

// readH4 reads one HCI packet in UART framing: the packet type, then its header,
// whose length field gives the rest.
func readH4(r io.Reader) ([]byte, error) {
	var t [1]byte
	if _, err := io.ReadFull(r, t[:]); err != nil {
		return nil, err
	}
	var hdr, lenAt int
	wide := false
	switch t[0] {
	case 0x01, 0x03: // command (opcode, length), SCO (handle, length)
		hdr, lenAt = 3, 2
	case 0x02, 0x05: // ACL, ISO: handle, 16-bit length
		hdr, lenAt, wide = 4, 2, true
	case 0x04: // event: code, length
		hdr, lenAt = 2, 1
	default:
		return nil, fmt.Errorf("unknown HCI packet type %#x", t[0])
	}
	p := make([]byte, 1+hdr)
	p[0] = t[0]
	if _, err := io.ReadFull(r, p[1:]); err != nil {
		return nil, err
	}
	n := int(p[1+lenAt])
	if wide {
		n = int(binary.LittleEndian.Uint16(p[1+lenAt:]))
		if t[0] == 0x05 {
			n &= 0x3FFF
		}
	}
	if len(p)+n > protocol.MaxHCIPacket {
		return nil, fmt.Errorf("HCI packet of %d bytes", len(p)+n)
	}
	p = append(p, make([]byte, n)...)
	if _, err := io.ReadFull(r, p[1+hdr:]); err != nil {
		return nil, err
	}
	return p, nil
}
