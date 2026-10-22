//go:build !linux && !windows

package agent

import "github.com/cioufong/vitrine/guest/linux-agent/protocol"

// Other platforms only build the agent for tests; they report nothing.
func sampleCPU() (cpuTimes, bool)      { return cpuTimes{}, false }
func sampleStats() protocol.GuestStats { return protocol.GuestStats{} }
