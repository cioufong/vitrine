package agent

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"net"
	"testing"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// bluetoothCaps is how many capabilities Bluetooth adds on this platform.
func bluetoothCaps() int {
	if bluetoothSupported() {
		return 1
	}
	return 0
}

func TestReadH4(t *testing.T) {
	stream := []byte{
		0x01, 0x03, 0x0C, 0x00, // HCI_Reset
		0x02, 0x40, 0x20, 0x03, 0x00, 0xAA, 0xBB, 0xCC, // ACL, 3 bytes
		0x04, 0x0E, 0x01, 0x01, // event
		0x05, 0x01, 0x00, 0x02, 0x40, 0x11, 0x22, // ISO: flag bits above the 14-bit length
	}
	r := bytes.NewReader(stream)
	for _, want := range [][]byte{stream[0:4], stream[4:12], stream[12:16], stream[16:23]} {
		p, err := readH4(r)
		if err != nil || !bytes.Equal(p, want) {
			t.Fatalf("got %x, %v; want %x", p, err, want)
		}
	}
	if _, err := readH4(r); err != io.EOF {
		t.Fatalf("at the end: %v", err)
	}
	if _, err := readH4(bytes.NewReader([]byte{0x09, 0})); err == nil {
		t.Fatal("unknown packet type accepted")
	}
	if _, err := readH4(bytes.NewReader([]byte{0x02, 0, 0, 0xFF, 0xFF})); err == nil {
		t.Fatal("oversized packet accepted")
	}
}

// fakeBridge replaces dialBluetooth for one test; each dial hands the test the
// bridge's end of the connection.
func fakeBridge(t *testing.T, fail error) chan net.Conn {
	ends := make(chan net.Conn, 4)
	old := dialBluetooth
	dialBluetooth = func() (net.Conn, error) {
		if fail != nil {
			return nil, fail
		}
		agentEnd, bridgeEnd := net.Pipe()
		ends <- bridgeEnd
		return agentEnd, nil
	}
	t.Cleanup(func() { dialBluetooth = old })
	return ends
}

func TestBluetoothRelay(t *testing.T) {
	ends := fakeBridge(t, nil)
	h, _ := newHost(t, New(&fakeBackend{}, false))
	expect[protocol.Hello](h)
	expect[protocol.DisplayInfo](h)

	h.send(protocol.BluetoothStart{})
	bridge := <-ends
	go bridge.Write([]byte("ok hci3\n\x01\x03\x10\x00"))
	if st := expect[protocol.BluetoothStatus](h); !st.Ready || st.Device != "hci3" {
		t.Fatalf("status %+v", st)
	}
	if p := expect[protocol.BluetoothHCI](h); !bytes.Equal(p, []byte{0x01, 0x03, 0x10, 0x00}) {
		t.Fatalf("packet %x", p)
	}
	h.send(protocol.BluetoothHCI{0x04, 0x0E, 0x04, 0x01, 0x03, 0x10, 0x00})
	got := make([]byte, 7)
	if _, err := io.ReadFull(bridge, got); err != nil || got[1] != 0x0E {
		t.Fatalf("bridge got %x, %v", got, err)
	}

	h.send(protocol.BluetoothStop{})
	if _, err := bufio.NewReader(bridge).ReadByte(); err != io.EOF {
		t.Fatalf("after stop: %v", err)
	}
}

// A stop handled before a start's worker gets going still cancels that start.
func TestBluetoothStopBeforeStartRuns(t *testing.T) {
	ends := fakeBridge(t, nil)
	guest, hostSide := pipe()
	go io.Copy(io.Discard, hostSide)
	s := &session{a: New(&fakeBackend{}, false), conn: NewConn(guest)}
	t.Cleanup(s.conn.Close)
	gen := s.closeBluetooth() // BluetoothStart dispatched
	s.closeBluetooth()        // BluetoothStop, before the worker ran
	done := make(chan struct{})
	go func() { s.bluetoothStart(gen); close(done) }()
	bridge := <-ends
	go bridge.Write([]byte("ok hci1\n"))
	<-done
	if _, err := bufio.NewReader(bridge).ReadByte(); err != io.EOF {
		t.Fatalf("the cancelled start kept the controller: %v", err)
	}
	s.btMu.Lock()
	defer s.btMu.Unlock()
	if s.bt != nil {
		t.Fatal("controller attached after the stop")
	}
}

func TestBluetoothBridgeMissingOrRefusing(t *testing.T) {
	fakeBridge(t, errors.New("connect: no such file or directory"))
	h, _ := newHost(t, New(&fakeBackend{}, false))
	expect[protocol.Hello](h)
	expect[protocol.DisplayInfo](h)
	h.send(protocol.BluetoothStart{})
	if st := expect[protocol.BluetoothStatus](h); st.Ready || st.Error != errNoBluetoothBridge.Error() || st.Installable == nil || !*st.Installable {
		t.Fatalf("status %+v", st)
	}

	ends := make(chan net.Conn, 1)
	dialBluetooth = func() (net.Conn, error) {
		a, b := net.Pipe()
		ends <- b
		return a, nil
	}
	h.send(protocol.BluetoothStart{})
	bridge := <-ends
	go bridge.Write([]byte("error attaching hci_uart: operation not permitted\n"))
	if st := expect[protocol.BluetoothStatus](h); st.Ready || st.Error != "attaching hci_uart: operation not permitted" {
		t.Fatalf("status %+v", st)
	}
}

func TestBluetoothControllerGoingAwayIsReported(t *testing.T) {
	ends := fakeBridge(t, nil)
	h, _ := newHost(t, New(&fakeBackend{}, false))
	expect[protocol.Hello](h)
	expect[protocol.DisplayInfo](h)
	h.send(protocol.BluetoothStart{})
	bridge := <-ends
	go func() {
		bridge.Write([]byte("ok hci0\n"))
		bridge.Close()
	}()
	if st := expect[protocol.BluetoothStatus](h); !st.Ready {
		t.Fatalf("status %+v", st)
	}
	if st := expect[protocol.BluetoothStatus](h); st.Ready || st.Error == "" {
		t.Fatalf("after close %+v", st)
	}
}
