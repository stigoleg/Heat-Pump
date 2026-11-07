#!/bin/zsh
# Captures one window of the Debug build in demo mode (simulated data, own database).
#
#   scripts/screenshot.sh <out.png> [ENV=VALUE ...]
#
# Options (environment variables of this script):
#   LANG_CODE=en|nb     app language (default en)
#   SIZE=1413x1049      main window size in points (default 1413x1049, the README size)
#   SCREEN=retina       put the window (and the menu bar panel) on the first 2x display, so the
#                       capture is sharp while a 1x monitor is the main display (SIZE must fit it)
#   WINDOW=settings     capture the Settings window instead (use with VARMEPUMPE_SETTINGS_TAB)
#   WINDOW=panel        capture the menu bar panel instead (use with VARMEPUMPE_MENU_BAR=open)
#   WINDOW=menubar      capture the menu bar item with a strip of the menu bar around it (use
#                       with VARMEPUMPE_MENU_BAR=on; PAD=12 points on each side)
#   WAIT=9              seconds to wait before capturing (demo data and charts settle)
#   MAXPX=2000          longest side of the saved PNG in pixels
#
# Any VARMEPUMPE_* variable can follow the file name, e.g.
#   scripts/screenshot.sh docs/screenshots/en/history-energy.png \
#       VARMEPUMPE_SCREEN=history VARMEPUMPE_HISTORY_TAB=energy VARMEPUMPE_APPEARANCE=light
#
# Requires `make debug` first. The window frame is a dev variable (VARMEPUMPE_WINDOW_FRAME) and
# saved window state is ignored, so the real app's window frame is neither used nor changed.
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
screen=$($tool --screen ${SCREEN:-})
read -r sx sy _ _ <<< "$screen"
[[ ${WINDOW:-} == menubar ]] && items_before=$($tool --status-items | cut -d' ' -f1)
# One demo database per language: simulated device names are stored when first seen.
mkdir -p build/demo "$(dirname "$out")"

env VARMEPUMPE_BACKEND=mock VARMEPUMPE_DB_PATH=$PWD/build/demo/varmepumpe-${LANG_CODE:-en}.sqlite \
    VARMEPUMPE_LANGUAGE=${LANG_CODE:-en} ${SCREEN:+VARMEPUMPE_SCREENSHOT_SCREEN=$SCREEN} \
    VARMEPUMPE_WINDOW_FRAME="$((sx + 40)) $((sy + 20)) $width $height" "$@" \
    $app -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
# A tiling window manager (AeroSpace) would size the window itself: float the demo window.
if command -v aerospace >/dev/null; then
    for attempt in 1 2 3 4 5 6; do
        sleep 1
        wid=$(aerospace list-windows --all --format '%{window-id} %{app-pid}' 2>/dev/null | awk -v p=$pid '$2 == p { print $1; exit }')
        if [[ -n $wid ]]; then
            # Its workspace's monitor wins over the window's frame: move it to the Retina one.
            [[ ${SCREEN:-} == retina ]] && { aerospace move-node-to-monitor --window-id $wid 'Retina' 2>/dev/null || true; }
            aerospace layout floating --window-id $wid 2>/dev/null || true
            break
        fi
    done
fi
sleep ${WAIT:-9}

if [[ ${WINDOW:-} == menubar ]]; then
    item=""
    for attempt in 1 2 3 4 5; do
        # The item that was not there before launch (Control Center owns it, not the app).
        for line in ${(f)"$($tool --status-items)"}; do
            (( ${${(f)items_before}[(Ie)${line%% *}]} == 0 )) && { item=$line; break; }
        done
        [[ -n $item ]] && break
        sleep 2
    done
    [[ -n $item ]] || { echo "No menu bar item found for $out (hidden behind the notch?)" >&2; exit 1; }
    read -r _ x y w h <<< "$item"
    pad=${PAD:-12}
    screencapture -o -x -R "$((x - pad)),$y,$((w + 2 * pad)),$h" "$out"
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    echo "$out"
    exit 0
fi

# The window can take a moment to appear on a busy machine.
id=""
for attempt in 1 2 3 4 5; do
    id=$($tool $pid ${WINDOW:+$([[ $WINDOW == panel ]] && echo panel || echo smallest)}) && break
    sleep 2
done
[[ -n $id ]] || { echo "No window found for $out" >&2; exit 1; }
screencapture -o -x -l $id "$out"
kill $pid 2>/dev/null || true
wait $pid 2>/dev/null || true
# Only ever scale down: a 1x display gives small images, and upscaling only blurs them.
longest=$(sips -g pixelWidth -g pixelHeight "$out" | awk '/pixel/ { if ($2 > m) m = $2 } END { print m }')
(( longest > ${MAXPX:-2000} )) && sips -Z ${MAXPX:-2000} "$out" >/dev/null
echo "$out"
