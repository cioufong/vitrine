#!/bin/sh
# Vitrine acceptance benchmark (macOS host, Linux and macOS guests). Prints KEY=VALUE lines.
#   CPU: 7-Zip LZMA (single thread and all threads, MIPS)
#   Memory: sysbench memory 1M blocks, sequential write (MiB/s)   [if sysbench exists]
#   Disk: fio 1 GiB sequential write/read and 4k random read (MB/s, IOPS) [if fio exists]
set -u
DIR=${1:-$HOME/vitrine-bench}
mkdir -p "$DIR"; cd "$DIR"
# Same 7-Zip release everywhere (26.04): bench results differ between versions.
Z=""
if [ "$(uname)" = Darwin ] && command -v 7zz >/dev/null && 7zz 2>&1 | grep -q " 26.04 "; then Z=$(command -v 7zz); fi
if [ -z "$Z" ]; then
  case "$(uname)-$(uname -m)" in
    Linux-aarch64) pkg=7z2604-linux-arm64.tar.xz ;;
    Linux-x86_64) pkg=7z2604-linux-x64.tar.xz ;;
    Darwin-*) pkg=7z2604-mac.tar.xz ;;
  esac
  [ -x "$DIR/7zz" ] || { curl -fsSL "https://www.7-zip.org/a/$pkg" -o "$DIR/7z.tar.xz" && tar -C "$DIR" -xf "$DIR/7z.tar.xz" 7zz; }
  Z="$DIR/7zz"
fi
echo "sevenzip=$("$Z" 2>&1 | grep -o '7-Zip (z) [0-9.]*' | head -1)"
if [ -n "$Z" ]; then
  out=$("$Z" b -mmt1 2>/dev/null)
  echo "cpu_1t_mips=$(echo "$out" | awk '/^Tot:/{print $4}')"
  echo "cpu_4t_mips=$("$Z" b -mmt4 2>/dev/null | awk '/^Tot:/{print $4}')"
  echo "cpu_mt_mips=$("$Z" b 2>/dev/null | awk '/^Tot:/{print $4}')"
fi
if command -v sysbench >/dev/null 2>&1; then
  echo "mem_write_mibs=$(sysbench memory --memory-block-size=1M --memory-total-size=20G run 2>/dev/null | awk '/MiB transferred/{gsub(/[()]/,"",$4); print $4}')"
fi
if command -v fio >/dev/null 2>&1; then
  common="--name=t --filename=$DIR/fio.dat --size=1G --direct=1 --ioengine=psync --group_reporting --minimal"
  [ "$(uname)" = Darwin ] && common="--name=t --filename=$DIR/fio.dat --size=1G --ioengine=posixaio --group_reporting --minimal"
  w=$(fio $common --rw=write --bs=1M 2>/dev/null | awk -F';' '{print $48}')
  r=$(fio $common --rw=read --bs=1M 2>/dev/null | awk -F';' '{print $7}')
  rr=$(fio $common --rw=randread --bs=4k --runtime=10 --time_based 2>/dev/null | awk -F';' '{print $8}')
  echo "disk_seq_write_kibs=$w"
  echo "disk_seq_read_kibs=$r"
  echo "disk_rand4k_read_iops=$rr"
  rm -f "$DIR/fio.dat"
fi
