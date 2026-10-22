//go:build !linux

package agent

func bluetoothSupported() bool { return false }
