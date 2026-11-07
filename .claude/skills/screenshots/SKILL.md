---
name: screenshots
description: Take Varmepumpe screenshots in demo mode at a fixed window size (for the README, docs, release notes or reviewing your own UI change) and run the visual parity check that proves a refactor did not change the look. Use when asked for screenshots, when updating docs/screenshots, after UI work, and before/after any refactor that must keep the app looking the same.
---

# Screenshots and visual parity

Everything runs the Debug build in demo mode (`VARMEPUMPE_BACKEND=mock`, database in
`build/demo/`), so no real account is touched. Build first: `make debug`.

## One screenshot

```sh
scripts/screenshot.sh <out.png> [VARMEPUMPE_…=value …]
```

Script options (environment): `LANG_CODE=en|nb` (default en), `SIZE=1413x1049` (window points;
the README size), `WINDOW=settings` (capture the Settings window), `WINDOW=panel` (capture the menu bar panel;
with `VARMEPUMPE_MENU_BAR=open`), `WAIT=9` (seconds before the
capture), `MAXPX=2000` (longest side of the saved PNG).

App hooks you can pass after the file name:

| Variable | Values |
|---|---|
| `VARMEPUMPE_SCREEN` | overview, control, schedule, history, outlook, away, health, activity; with two or more devices also home, home/forecast, home/activity and `<device key>/<screen>` (e.g. demo:100002/control) |
| `VARMEPUMPE_HISTORY_TAB` | temperature, energy, energy-kr, operation, power |
| `VARMEPUMPE_HISTORY_RANGE` | day, week, month, year |
| `VARMEPUMPE_SETTINGS_TAB` | generelt, konto, enheter, strompris, lokal, vaer, claude, data (opens Settings; use `WINDOW=settings`) |
| `VARMEPUMPE_SCROLL_TO` | a section `.id(…)` on the screen; scrolls there after 3 s (also `menubar` on Settings → General) |
| `VARMEPUMPE_APPEARANCE` | light, dark, system (not saved) |
| `VARMEPUMPE_MOCK_CYCLING` | short (simulated short cycling, for Health) |
| `VARMEPUMPE_DEMO_DEVICES` | heatpump (default), heatpump,heatpump (adds “Bedroom (simulated)”, for multi-device screens), heatpump,meter (adds the simulated Tibber home `demo-meter:home`: screens `demo-meter:home/overview` and `/history`), heatpump,airthings (adds the simulated Airthings sensor `demo-airquality:2930000001`: screens `demo-airquality:2930000001/overview` and `/history`) |
| `VARMEPUMPE_SETTINGS_SHEET` | add-integration (opens Add Device on the Devices tab; with `VARMEPUMPE_SETTINGS_TAB=enheter` and `WINDOW=settings`), add-integration/<id> (the same, on that service, e.g. `add-integration/airthings`) |
| `VARMEPUMPE_ADD_DEVICE` | 1 (opens Add Device in the main window), or an integration id to open on that service |
| `VARMEPUMPE_MENU_BAR` | on, off (overrides Settings → General → Menu bar without saving), open (also opens the panel; with `WINDOW=panel`). A full menu bar hides the item; the dev hook then moves the panel on screen |

The window size is passed as an argument-domain default, so the real app's saved window frame is
not changed. The script compiles `scripts/tools/window-id.swift` into `build/tools/` on first use.
Captured windows look inactive (grey traffic lights); that is expected and consistent.

Look at the result with the Read tool before using it.

## README screenshots

Files live in `docs/screenshots/en/` and `docs/screenshots/nb/` with the same names, light
appearance unless the name says dark, 2000 px wide (Settings 1200 px: `MAXPX=1200`):

```sh
for lang in en nb; do
  LANG_CODE=$lang scripts/screenshot.sh docs/screenshots/$lang/overview-light.png VARMEPUMPE_SCREEN=overview VARMEPUMPE_APPEARANCE=light
  LANG_CODE=$lang scripts/screenshot.sh docs/screenshots/$lang/history-energy.png VARMEPUMPE_SCREEN=history VARMEPUMPE_HISTORY_TAB=energy VARMEPUMPE_APPEARANCE=light
  LANG_CODE=$lang WINDOW=settings MAXPX=1200 scripts/screenshot.sh docs/screenshots/$lang/settings-price.png VARMEPUMPE_SETTINGS_TAB=strompris VARMEPUMPE_APPEARANCE=light
done
```

Check the README tables still point at existing files. Never commit photos of the unit's label
(they contain the Wi-Fi key; `*.HEIC`/`*.jpg` are git-ignored for that reason).

## Visual parity (refactors)

```sh
make debug && scripts/parity.sh capture build/parity/baseline   # before the change
# … change …
make debug && scripts/parity.sh capture build/parity/after
scripts/parity.sh compare build/parity/baseline build/parity/after
```

`capture` takes every screen, History tab and Settings tab in English and Norwegian (light) plus
Overview dark (about 40 images, 7 minutes; demo windows open and close on screen). It is always
one device. `scripts/parity.sh capture-multi <dir>` takes the multi-device screens
(`VARMEPUMPE_DEMO_DEVICES=heatpump,heatpump`: Home, Forecast, Claude activity, the bedroom's
screens, Account and Local connection) into their own folder; compare them only with another
multi-device set. `compare`
prints the share of differing pixels per image and writes red-marked diff images to
`<after>/diff/` for anything above 0.5 %.

Demo data follows the clock: chart edges, "just now"/"x minutes ago" and the date pickers move
between runs. Read each diff image and decide whether the difference is data drift or a real
change; a real change in layout, text, colour or a missing element is a regression to fix unless
the task asked for it. Capture the baseline and the after set close in time.
