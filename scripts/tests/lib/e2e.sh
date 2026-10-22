# Shared prologue of the QEMU end-to-end tests in scripts/tests: source it right after `set` (it sets
# no shell options itself). It moves to the repository root and provides:
#   e2e_iso <glob>     the newest cached image matching <glob> under the Linux cache, or nothing
#   e2e_setup <vm>...  builds vitrinectl (debug) into $BIN, points VITRINE_HOME at a throwaway library
#                      and, on exit, force-stops those VMs and removes the library and the one path in $E2E_CLEANUP
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
E2E_CACHE="${VITRINE_CACHE:-$HOME/Library/Caches/Vitrine}/linux"
E2E_CLEANUP=""
E2E_VMS=""

e2e_iso() { { ls "$E2E_CACHE"/$1 2>/dev/null || true; } | tail -1; }

e2e_setup() {
    BIN=$(./scripts/build-cli.sh debug | tail -1)
    export VITRINE_HOME=$(mktemp -d)
    E2E_VMS="$*"
    trap e2e_cleanup EXIT
}

e2e_cleanup() {
    for vm in $E2E_VMS; do "$BIN" stop "$vm" --force >/dev/null 2>&1 || true; done
    rm -rf "$VITRINE_HOME" ${E2E_CLEANUP:+"$E2E_CLEANUP"}
}
