package agent

import (
	"bufio"
	"strconv"
	"strings"
)

// parseProcStat reads the aggregate "cpu" line of /proc/stat.
func parseProcStat(text string) (cpuTimes, bool) {
	line, _, _ := strings.Cut(text, "\n")
	f := strings.Fields(line)
	if len(f) < 5 || f[0] != "cpu" {
		return cpuTimes{}, false
	}
	var t cpuTimes
	// user nice system idle iowait irq softirq steal [guest guest_nice]; guest
	// time is already counted in user and nice.
	for i, s := range f[1:] {
		if i >= 8 {
			break
		}
		n, err := strconv.ParseUint(s, 10, 64)
		if err != nil {
			return cpuTimes{}, false
		}
		t.total += n
		if i != 3 && i != 4 {
			t.busy += n
		}
	}
	return t, true
}

// parseMeminfo returns MemTotal and MemTotal-MemAvailable from /proc/meminfo, in bytes.
func parseMeminfo(text string) (total, used uint64, ok bool) {
	var avail uint64
	var haveTotal, haveAvail bool
	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 2 {
			continue
		}
		n, err := strconv.ParseUint(f[1], 10, 64)
		if err != nil {
			continue
		}
		switch f[0] {
		case "MemTotal:":
			total, haveTotal = n*1024, true
		case "MemAvailable:":
			avail, haveAvail = n*1024, true
		}
	}
	if !haveTotal || !haveAvail || avail > total {
		return 0, 0, false
	}
	return total, total - avail, true
}
