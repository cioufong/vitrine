//go:build linux

package agent

// bluetoothSupported: Linux kernels take a controller over a tty (hci_uart),
// which the bridge sets up.
func bluetoothSupported() bool { return true }
