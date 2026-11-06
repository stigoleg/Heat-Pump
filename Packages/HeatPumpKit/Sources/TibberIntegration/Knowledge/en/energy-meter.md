# The energy meter (Tibber)

The app reads the home's electricity use from Tibber with the same personal access token as the Tibber prices.

## Hourly use

- Tibber reports the whole home's use per hour, with Tibber's own cost for each hour.
- The data is not real time: the last few hours often arrive 2–3 hours late, and an hour that is not finished yet is left out. The app asks Tibber at most once an hour.
- The app prices every hour like the rest of the app: your electricity contract, the grid tariff's energy charge and the electricity subsidy. Tibber's own cost does not include the grid tariff, so the two differ.

## Live power

- Live power needs a real-time meter reader paired with the home in the Tibber app (Tibber Pulse or Watty). Without one, only the hourly use is shown.
- The reader sends a new value every few seconds; how often depends on the meter.
- Live power is only read while the app is open and the meter is turned on. The app keeps one connection to Tibber and pauses it while the Mac sleeps.
- Today's use so far comes from the reader's counter since midnight until Tibber's hourly data catches up.

## The heat pump's share

With a heat pump in the app, the home's use is shown next to the heat pump's, so you can see how much of the home's electricity the heat pump uses. The share is given for days where both are known for at least 20 hours.

## Good to know

- Tibber limits how often apps may ask. The app stays far below the limit, and a refused token is never tried again until you save a new one.
- The token is stored in the keychain on this Mac.
