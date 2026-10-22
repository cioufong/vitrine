#!/bin/bash
# Regenerates THIRD_PARTY_NOTICES from the license files of the Go modules (and the Go standard
# library) that are compiled into the bundled guest agents. Run after changing guest/linux-agent/go.mod.
set -euo pipefail
cd "$(dirname "$0")/.."
out=THIRD_PARTY_NOTICES
modcache=$(go env GOMODCACHE)
goroot=$(cd guest/linux-agent && go env GOROOT)
{
  echo "Third-party software in Vitrine"
  echo "==============================="
  echo
  echo "Vitrine.app bundles guest agents for Linux and Windows built from guest/linux-agent. Those"
  echo "binaries statically include the following components. QEMU, swtpm and Samba are not"
  echo "distributed with Vitrine; they run as separate programs installed by the user."
  echo
  emit() { # name version license-file
    echo "------------------------------------------------------------------------------"
    echo "$1${2:+ $2}"
    echo "------------------------------------------------------------------------------"
    sed -e 's#^// \{0,1\}##' "$3"
    echo
  }
  # No toolchain version in the heading: CI and local builds may use different Go patch releases.
  emit "Go standard library" "" "$goroot/LICENSE"
  (cd guest/linux-agent && go list -m -f '{{if not .Main}}{{.Path}} {{.Version}}{{end}}' all) | while read -r path version; do
    [ -n "$path" ] || continue
    dir="$modcache/$path@$version"
    lic=""
    for f in "$dir"/LICENSE* "$dir"/COPYING*; do [ -f "$f" ] && { lic=$f; break; }; done
    [ -n "$lic" ] || { echo "no license file for $path $version" >&2; exit 1; }
    emit "$path" "$version" "$lic"
  done
} > "$out"
echo "wrote $out"
