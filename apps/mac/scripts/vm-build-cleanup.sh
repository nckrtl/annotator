# Source after changing to the build's working directory. Optional outside nick-vm.
# Only pass intermediates whose products have already been copied to their final path.
vm_build_guard=${VM_DISK_GUARD:-${HOME}/bin/vm-disk-guard}
vm_build_guard_outer=${VM_BUILD_GUARD_ACTIVE:-0}
if [[ -x $vm_build_guard && $vm_build_guard_outer == 0 ]]; then
  "$vm_build_guard" --no-simulators > "$HOME/Library/Logs/vm-build-cleanup.log" 2>&1 || {
    echo 'VM disk guard failed. See ~/Library/Logs/vm-build-cleanup.log.' >&2
    exit 1
  }
fi
export VM_BUILD_GUARD_ACTIVE=1
vm_build_cleanup() {
  local build_status=$1 cleanup_path
  shift
  local cleanup_args=()
  for cleanup_path in "$@"; do
    [[ -n $cleanup_path && -e $cleanup_path ]] || continue
    cleanup_args+=(--finished-path "$cleanup_path")
  done
  if [[ -x $vm_build_guard ]]; then
    if [[ ${#cleanup_args[@]} -gt 0 ]]; then
      "$vm_build_guard" "${cleanup_args[@]}" >> "$HOME/Library/Logs/vm-build-cleanup.log" 2>&1 ||
        echo 'VM intermediate cleanup needs attention; see ~/Library/Logs/vm-build-cleanup.log.' >&2
    fi
    if [[ $vm_build_guard_outer == 0 ]]; then
      "$vm_build_guard" --no-simulators >> "$HOME/Library/Logs/vm-build-cleanup.log" 2>&1 ||
        echo 'VM disk guard needs attention; see ~/Library/Logs/vm-build-cleanup.log.' >&2
    fi
  fi
  return "$build_status"
}
