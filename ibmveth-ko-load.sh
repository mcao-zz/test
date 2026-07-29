# Shared ibmveth load helper. Source from env.sh / lab monoliths.
# IBMVETH_KO=/path/to/ibmveth.ko  or  directory containing ibmveth.ko
# Unset → modprobe.
#
# Usage:
#   ibmveth_module_load [dyndbg]   # e.g. ibmveth_module_load "+p"
# Returns 0 on success, 1 on failure (prints to stderr).

ibmveth_resolve_ko() {
	local p=${IBMVETH_KO:-}

	[[ -n "$p" ]] || return 1
	if [[ -d "$p" ]]; then
		p="$p/ibmveth.ko"
	fi
	[[ -f "$p" ]] || {
		echo "IBMVETH_KO not found: $IBMVETH_KO" >&2
		return 1
	}
	( cd "$(dirname "$p")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$p")" )
}

ibmveth_module_load() {
	local dyndbg=${1:-}
	local ko
	local -a cmd=()

	if [[ $(id -u) -ne 0 ]]; then
		cmd=(sudo)
	fi

	if ko=$(ibmveth_resolve_ko); then
		echo "loading ibmveth from IBMVETH_KO=$ko${dyndbg:+ dyndbg=$dyndbg}" >&2
		if [[ -n "$dyndbg" ]]; then
			"${cmd[@]}" insmod "$ko" "dyndbg=$dyndbg"
		else
			"${cmd[@]}" insmod "$ko"
		fi
	else
		[[ -z "${IBMVETH_KO:-}" ]] || return 1
		echo "loading ibmveth via modprobe${dyndbg:+ dyndbg=$dyndbg}" >&2
		if [[ -n "$dyndbg" ]]; then
			"${cmd[@]}" modprobe ibmveth "dyndbg=$dyndbg"
		else
			"${cmd[@]}" modprobe ibmveth
		fi
	fi
}
