#!/bin/zsh
# Visual parity check for refactors that must not change how the app looks.
#
#   scripts/parity.sh capture <dir>          screenshots of every screen, History tab and
#                                            Settings tab (English light, Overview dark,
#                                            Norwegian light) in demo mode
#   scripts/parity.sh compare <before> <after>
#                                            per image: % of differing pixels, and a diff image
#                                            in <after>/diff/ for anything above 0.5 %
#
# Typical use: `make debug && scripts/parity.sh capture build/parity/baseline` before the
# change, the same into build/parity/after afterwards, then compare. Demo data follows the
# clock, so charts and "x minutes ago" texts drift between runs; capture both sets close in
# time and look at the diff images rather than trusting the numbers alone.
set -euo pipefail
cd "$(dirname "$0")/.."

capture() {
    local dir=$1
    mkdir -p $dir
    local shot=scripts/screenshot.sh
    for lang in en nb; do
        for screen in overview control schedule outlook away health activity; do
            LANG_CODE=$lang $shot $dir/$lang-$screen.png VARMEPUMPE_SCREEN=$screen VARMEPUMPE_APPEARANCE=light
        done
        for tab in temperature energy energy-kr operation power; do
            LANG_CODE=$lang $shot $dir/$lang-history-$tab.png VARMEPUMPE_SCREEN=history \
                VARMEPUMPE_HISTORY_TAB=$tab VARMEPUMPE_APPEARANCE=light
        done
        for tab in generelt konto strompris lokal vaer claude data; do
            LANG_CODE=$lang WINDOW=settings MAXPX=1400 $shot $dir/$lang-settings-$tab.png \
                VARMEPUMPE_SETTINGS_TAB=$tab VARMEPUMPE_APPEARANCE=light
        done
    done
    LANG_CODE=en $shot $dir/en-overview-dark.png VARMEPUMPE_SCREEN=overview VARMEPUMPE_APPEARANCE=dark
}

compare() {
    local before=$1 after=$2
    local tool=build/tools/image-diff
    if [[ ! -x $tool || scripts/tools/image-diff.swift -nt $tool ]]; then
        mkdir -p build/tools
        swiftc -O scripts/tools/image-diff.swift -o $tool
    fi
    mkdir -p $after/diff
    local failed=0
    for a in $before/*.png; do
        local name=${a:t}
        local b=$after/$name
        if [[ ! -f $b ]]; then
            echo "missing  $name"; failed=1; continue
        fi
        local pct
        pct=$($tool $a $b $after/diff/$name) || true
        if [[ $pct == size ]]; then
            echo "SIZE     $name"; failed=1
        elif (( pct > 0.5 )); then
            echo "$pct%    $name  -> $after/diff/$name"; failed=1
        else
            echo "ok $pct% $name"; rm -f $after/diff/$name
        fi
    done
    return $failed
}

case ${1:-} in
    capture) capture ${2:?directory} ;;
    compare) compare ${2:?before} ${3:?after} ;;
    *) echo "usage: scripts/parity.sh capture <dir> | compare <before> <after>" >&2; exit 2 ;;
esac
