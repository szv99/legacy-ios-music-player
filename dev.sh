#!/bin/bash
# Build / install / debug loop for Player7 on the tethered iOS 7 iPhone.
#   ./dev.sh            build, install over USB, launch, stream logs
#   ./dev.sh build      compile only
#   ./dev.sh install    build + install + launch (no logs)
#   ./dev.sh logs       stream app logs (NSLog) from the device
#   ./dev.sh ipa        build a release .ipa into packages/
#   ./dev.sh shot [name] [cmd...]  run player7:// commands, then save a screenshot to shots/<name>.png
#   ./dev.sh cmd <cmd>...          run player7:// debug commands (see Sources/P7Debug.h)
#   ./dev.sh ssh        root shell on the device
#   ./dev.sh boot       tether boot the phone (put it in DFU first)
set -euo pipefail

cd "$(dirname "$0")"
export THEOS="${THEOS:-$HOME/theos}"
LIK="$HOME/Legacy-iOS-Kit"
BIN="$LIK/bin/macos"
APP="Player7"
DEVICE_ALIAS="iphone5c"   # Host entry in ~/.ssh/config -> 127.0.0.1:2222
PORT=2222

tool() { if [[ -x "$BIN/$1" ]]; then echo "$BIN/$1"; else command -v "$1"; fi; }

tunnel() {
	if ! pgrep -f "iproxy $PORT 22" >/dev/null; then
		"$(tool iproxy)" "$PORT" 22 >/dev/null 2>&1 &
		disown
		sleep 1
	fi
	if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$DEVICE_ALIAS" true 2>/dev/null; then
		echo "Device not reachable over SSH. Is the phone booted and connected?" >&2
		exit 1
	fi
}

logs() {
	echo "--- logs for $APP (Ctrl+C to stop) ---"
	"$(tool idevicesyslog)" 2>/dev/null | grep --line-buffered -E "$APP\[|\[$APP\]"
}

make_device() {
	make "$@" THEOS_DEVICE_IP="$DEVICE_ALIAS" THEOS_DEVICE_PORT="$PORT" THEOS_DEVICE_USER=root
}

case "${1:-run}" in
	run)     tunnel; make_device do; logs ;;
	build)   make ;;
	install) tunnel; make_device do ;;
	logs)    logs ;;
	ipa)     make clean package FINALPACKAGE=1 PACKAGE_FORMAT=ipa; ls -1 packages/*.ipa ;;
	cmd)     tunnel; shift; for c in "$@"; do ssh "$DEVICE_ALIAS" "uiopen 'player7://$c'"; sleep 0.6; done ;;
	shot)    tunnel; name="${2:-screen}"; shift; shift || true
	         for c in "$@"; do ssh "$DEVICE_ALIAS" "uiopen 'player7://$c'"; sleep 0.8; done
	         ssh "$DEVICE_ALIAS" "rm -f /tmp/player7-screenshot.png; uiopen player7://screenshot"; sleep 2.5
	         mkdir -p shots; scp -q "$DEVICE_ALIAS:/tmp/player7-screenshot.png" "shots/$name.png" && echo "shots/$name.png" ;;
	ssh)     tunnel; exec ssh "$DEVICE_ALIAS" ;;
	boot)    cd "$LIK" && exec ./restore.sh --just-boot --build-id=11D257 ;;
	*)       sed -n '2,11p' "$0"; exit 1 ;;
esac
