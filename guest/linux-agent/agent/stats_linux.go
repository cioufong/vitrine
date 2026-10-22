package agent

import (
	"os"
	"strconv"
	"strings"
	"syscall"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

func sampleCPU() (cpuTimes, bool) {
	b, err := os.ReadFile("/proc/stat")
	if err != nil {
		return cpuTimes{}, false
	}
	return parseProcStat(string(b))
}

func sampleStats() protocol.GuestStats {
	var st protocol.GuestStats
	if b, err := os.ReadFile("/proc/meminfo"); err == nil {
		if total, used, ok := parseMeminfo(string(b)); ok {
			st.MemoryTotal, st.MemoryUsed = u64(total), u64(used)
		}
	}
	var fs syscall.Statfs_t
	if syscall.Statfs("/", &fs) == nil && fs.Blocks >= fs.Bfree {
		bs := uint64(fs.Bsize)
		st.DiskTotal, st.DiskUsed = u64(fs.Blocks*bs), u64((fs.Blocks-fs.Bfree)*bs)
	}
	if b, err := os.ReadFile("/proc/uptime"); err == nil {
		if f := strings.Fields(string(b)); len(f) > 0 {
			if secs, err := strconv.ParseFloat(f[0], 64); err == nil && secs >= 0 {
				st.UptimeSeconds = u64(uint64(secs))
			}
		}
	}
	return st
}
