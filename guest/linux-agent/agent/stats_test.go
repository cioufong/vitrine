package agent

import "testing"

func TestParseProcStat(t *testing.T) {
	got, ok := parseProcStat("cpu  100 5 50 800 20 3 2 1 40 0\ncpu0 1 2 3 4\n")
	if !ok {
		t.Fatal("not parsed")
	}
	// busy = user+nice+system+irq+softirq+steal; total adds idle and iowait; guest excluded.
	if got.busy != 161 || got.total != 981 {
		t.Fatalf("got %+v", got)
	}
	if _, ok := parseProcStat("intr 1 2 3"); ok {
		t.Fatal("parsed a non-cpu line")
	}
}

func TestCPUPercent(t *testing.T) {
	p := cpuPercent(cpuTimes{busy: 100, total: 1000}, cpuTimes{busy: 150, total: 1200})
	if p == nil || *p != 25 {
		t.Fatalf("got %v", p)
	}
	if cpuPercent(cpuTimes{busy: 1, total: 10}, cpuTimes{busy: 1, total: 10}) != nil {
		t.Fatal("no elapsed time should give nil")
	}
}

func TestParseMeminfo(t *testing.T) {
	total, used, ok := parseMeminfo("MemTotal:        4000000 kB\nMemFree:  100 kB\nMemAvailable:    3000000 kB\n")
	if !ok || total != 4000000*1024 || used != 1000000*1024 {
		t.Fatalf("got %d %d %v", total, used, ok)
	}
	if _, _, ok := parseMeminfo("MemTotal: 10 kB\n"); ok {
		t.Fatal("parsed without MemAvailable")
	}
}
