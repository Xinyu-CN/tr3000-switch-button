#!/bin/sh
# Generic physical-switch controller. No VPN/network dependencies.
RUN_DIR=${RUN_DIR:-/tmp/tr3000-switch}
GPIO_FILE=${GPIO_FILE:-/sys/kernel/debug/gpio}

log() { logger -t tr3000-switch -- "$*"; }
fail() { log "ERROR: $*"; printf '%s\n' "$*" >&2; return 1; }
cfg() { uci -q get "tr3000-switch.main.$1" 2>/dev/null || printf '%s\n' "${2-}"; }

runtime_init() {
	umask 077
	mkdir -p "$RUN_DIR" || return 1
	chmod 755 "$RUN_DIR"
}

write_value() {
	local tmp
	tmp=$(mktemp "$RUN_DIR/.write.XXXXXX") || return 1
	printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$RUN_DIR/$1"
}

worker_lock() {
	local owner
	if ! mkdir "$RUN_DIR/worker.lock" 2>/dev/null; then
		owner=$(cat "$RUN_DIR/worker.lock/owner" 2>/dev/null) || return 1
		case "$owner" in ''|*[!0-9]*) return 1;; esac
		kill -0 "$owner" 2>/dev/null && return 1
		rm -f "$RUN_DIR/worker.lock/owner"
		rmdir "$RUN_DIR/worker.lock" 2>/dev/null || return 1
		mkdir "$RUN_DIR/worker.lock" 2>/dev/null || return 1
	fi
	printf '%s\n' "$$" > "$RUN_DIR/worker.lock/owner"
}

worker_unlock() {
	rm -f "$RUN_DIR/worker.lock/owner"
	rmdir "$RUN_DIR/worker.lock" 2>/dev/null || :
}

load_settings() {
	ENABLED=$(cfg enabled 0)
	BUTTON=$(cfg button BTN_0)
	GPIO_LABEL=$(cfg gpio_label mode)
	INVERT=$(cfg invert 0)
	POLL=$(cfg poll_seconds 1)
	SAMPLES=$(cfg stable_samples 2)
	RETRY=$(cfg retry_seconds 30)
	ACTION_TIMEOUT=$(cfg action_timeout 30)
	CHECK_INTERVAL=$(cfg check_interval 0)
	ACTION_SCRIPT=$(cfg action /etc/tr3000-switch/action.sh)
	case "$INVERT:$ENABLED" in [01]:[01]) ;; *) fail 'enabled/invert must be 0 or 1'; return 1;; esac
	local n
	for n in "$POLL" "$SAMPLES" "$RETRY" "$ACTION_TIMEOUT"; do
		case "$n" in ''|*[!0-9]*) fail 'timeouts and sample counts must be positive integers'; return 1;; esac
		[ "$n" -ge 1 ] && [ "$n" -le 300 ] || return 1
	done
	case "$CHECK_INTERVAL" in ''|*[!0-9]*) return 1;; esac
	[ "$CHECK_INTERVAL" -le 86400 ] || return 1
	case "$ACTION_SCRIPT" in /*) ;; *) fail 'action must be an absolute script path'; return 1;; esac
}

read_gpio() {
	[ -r "$GPIO_FILE" ] || return 1
	# Global GPIO numbers vary. debugfs reports raw levels + ACTIVE LOW flag.
	awk -v label="$GPIO_LABEL" '
		/^[[:space:]]*gpio-[0-9]+/ && /\|/ {
			split($0, parts, "|")
			consumer=parts[2]; sub(/\).*/, "", consumer)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", consumer)
			if (consumer != label) next
			n++
			if ($0 ~ /[[:space:]]lo([[:space:]]|$)/) level=0
			else if ($0 ~ /[[:space:]]hi([[:space:]]|$)/) level=1
			else { bad=1; next }
			state=($0 ~ /ACTIVE LOW/) ? 1-level : level
		}
		END { if (n!=1 || bad) exit 1; print state ? "on" : "off" }
	' "$GPIO_FILE"
}

physical_state() {
	local state
	state=$(read_gpio) || state=$(cat "$RUN_DIR/event" 2>/dev/null) || return 1
	case "$state" in on|off) ;; *) return 1;; esac
	if [ "$INVERT" = 1 ]; then
		case "$state" in on) state=off;; off) state=on;; esac
	fi
	printf '%s\n' "$state"
}

desired_state() {
	local override
	override=$(cat "$RUN_DIR/override" 2>/dev/null)
	case "$override" in on|off) printf '%s\n' "$override";; *) physical_state;; esac
}

run_action() {
	[ -f "$ACTION_SCRIPT" ] && [ -x "$ACTION_SCRIPT" ] || { fail "script missing/not executable: $ACTION_SCRIPT"; return 1; }
	# One executable path + arguments, never eval configuration text.
	TR3000_SWITCH_STATE="$1" TR3000_SWITCH_PREVIOUS="${2:-unknown}" \
		timeout "$ACTION_TIMEOUT" "$ACTION_SCRIPT" "$1"
}

check_action() {
	TR3000_SWITCH_STATE="$1" timeout "$ACTION_TIMEOUT" "$ACTION_SCRIPT" check "$1"
}

apply_state() {
	local rc=0 previous
	previous=$(cat "$RUN_DIR/applied" 2>/dev/null || printf unknown)
	write_value desired "$1"
	write_value status applying
	run_action "$1" "$previous" || rc=$?
	if [ "$rc" = 0 ]; then
		write_value applied "$1"
		write_value status ready
		log "action $1 applied"
	else
		write_value status error
		log "action $1 failed ($rc); will retry"
	fi
	return "$rc"
}
