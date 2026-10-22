package win

import (
	"errors"
	"io/fs"
)

// UseSerial decides the default transport from the result of opening the
// virtio-serial port (transport.DefaultWindowsSerialPath). Only QEMU on the
// Mac drives the other end of that port, so when it exists the agent uses it
// and never opens the TCP listener, which guest programs can reach through
// slirp (10.0.2.2:<hostport> loops back with the host's peer address).
//
// TCP is the fallback only when the port does not exist (an older VM without
// the port, or no vioser driver). Any other failure, such as another process
// already holding the port, keeps the agent on serial, retrying: falling back
// would let a guest program downgrade the agent to the reachable TCP port.
func UseSerial(openErr error) bool {
	return openErr == nil || !errors.Is(openErr, fs.ErrNotExist)
}
