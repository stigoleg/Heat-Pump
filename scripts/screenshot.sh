#!/bin/zsh
# Captures one window of the Debug build in demo mode (simulated data, own database).
#
#   scripts/screenshot.sh <out.png> [ENV=VALUE ...]
#
# Options (environment variables of this script):
#   LANG_CODE=en|nb     app language (default en)
#   SIZE=1413x1049      main window size in points (default 1413x1049, the README size)
#   WINDOW=settings     capture the Settings window instead (use with VARMEPUMPE_SETTINGS_TAB)
#   WAIT=9              seconds to wait before capturing (demo data and charts settle)
#   MAXPX=2000          longest side of the saved PNG in pixels
#
# Any VARMEPUMPE_* variable can follow the file name, e.g.
#   scripts/screenshot.sh docs/screenshots/en/history-energy.png \
#       VARMEPUMPE_SCREEN=history VARMEPUMPE_HISTORY_TAB=energy VARMEPUMPE_APPEARANCE=light
#
# Requires `make debug` first. The window size is passed in the argument domain, so the saved
# window frame of the real app is not changed.
set -euo pipefail
cd "$(dirname "$0")/.."

out=${1:?usage: scripts/screenshot.sh <out.png> [ENV=VALUE ...]}
shift
app=build/DerivedData/Build/Products/Debug/Varmepumpe.app/Contents/MacOS/Varmepumpe
[[ -x $app ]] || { echo "No Debug build; run make debug first." >&2; exit 1; }

tool=build/tools/window-id
if [[ ! -x $tool || scripts/tools/window-id.swift -nt $tool ]]; then
    mkdir -p build/tools
    swiftc -O scripts/tools/window-id.swift -o $tool
fi

size=${SIZE:-1413x1049}
width=${size%x*}
height=${size#*x}
screen=$($tool --screen)
mkdir -p build/demo "$(dirname "$out")"

env VARMEPUMPE_BACKEND=mock VARMEPUMPE_DB_PATH=$PWD/build/demo/varmepumpe.sqlite \
    VARMEPUMPE_LANGUAGE=${LANG_CODE:-en} "$@" \
    $app -"NSWindow Frame main-AppWindow-1" "200 40 $width $height $screen " >/dev/null 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
sleep ${WAIT:-9}

# The window can take a moment to appear on a busy machine.
id=""
for attempt in 1 2 3 4 5; do
    id=$($tool $pid ${WINDOW:+smallest}) && break
    sleep 2
done
[[ -n $id ]] || { echo "No window found for $out" >&2; exit 1; }
screencapture -o -x -l $id "$out"
kill $pid 2>/dev/null || true
wait $pid 2>/dev/null || true
sips -Z ${MAXPX:-2000} "$out" >/dev/null
echo "$out"
