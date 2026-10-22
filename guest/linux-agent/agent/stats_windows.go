package agent

import (
	"unsafe"

	"golang.org/x/sys/windows"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

var (
	kernel32                 = windows.NewLazySystemDLL("kernel32.dll")
	procGetSystemTimes       = kernel32.NewProc("GetSystemTimes")
	procGlobalMemoryStatusEx = kernel32.NewProc("GlobalMemoryStatusEx")
	procGetTickCount64       = kernel32.NewProc("GetTickCount64")
)

// sampleCPU uses GetSystemTimes; kernel time includes idle time.
func sampleCPU() (cpuTimes, bool) {
	var idle, kernel, user windows.Filetime
	r, _, _ := procGetSystemTimes.Call(uintptr(unsafe.Pointer(&idle)), uintptr(unsafe.Pointer(&kernel)), uintptr(unsafe.Pointer(&user)))
	if r == 0 {
		return cpuTimes{}, false
	}
	ft := func(f windows.Filetime) uint64 { return uint64(f.HighDateTime)<<32 | uint64(f.LowDateTime) }
	total := ft(kernel) + ft(user)
	if ft(idle) > total {
		return cpuTimes{}, false
	}
	return cpuTimes{busy: total - ft(idle), total: total}, true
}

type memoryStatusEx struct {
	Length               uint32
	MemoryLoad           uint32
	TotalPhys            uint64
	AvailPhys            uint64
	TotalPageFile        uint64
	AvailPageFile        uint64
	TotalVirtual         uint64
	AvailVirtual         uint64
	AvailExtendedVirtual uint64
}

func sampleStats() protocol.GuestStats {
	var st protocol.GuestStats
	m := memoryStatusEx{Length: uint32(unsafe.Sizeof(memoryStatusEx{}))}
	if r, _, _ := procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&m))); r != 0 && m.AvailPhys <= m.TotalPhys {
		st.MemoryTotal, st.MemoryUsed = u64(m.TotalPhys), u64(m.TotalPhys-m.AvailPhys)
	}
	drive := `C:\`
	if dir, err := windows.GetWindowsDirectory(); err == nil && len(dir) >= 3 {
		drive = dir[:3]
	}
	var free, total, totalFree uint64
	if p, err := windows.UTF16PtrFromString(drive); err == nil &&
		windows.GetDiskFreeSpaceEx(p, &free, &total, &totalFree) == nil && totalFree <= total {
		st.DiskTotal, st.DiskUsed = u64(total), u64(total-totalFree)
	}
	if ms, _, _ := procGetTickCount64.Call(); ms > 0 {
		st.UptimeSeconds = u64(uint64(ms) / 1000)
	}
	return st
}
