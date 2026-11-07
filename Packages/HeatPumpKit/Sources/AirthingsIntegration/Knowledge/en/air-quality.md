# Indoor air quality (Airthings)

The app reads your Airthings sensors through Airthings' API with an API client you create yourself. It only reads; it never changes anything on the sensors.

## What the values mean

| Value | What it is | Good | Fair | Poor |
|---|---|---|---|---|
| Radon | A radioactive gas from the ground. Long exposure raises the risk of lung cancer. | below 100 Bq/m³ | 100–150 | 150 or more |
| CO₂ | Carbon dioxide from breathing. A sign of how well the room is aired. | below 800 ppm | 800–1000 | 1000 or more |
| VOC | Volatile organic compounds from furniture, paint, cleaning and cooking. | below 250 ppb | 250–2000 | 2000 or more |
| PM2.5 / PM1 | Fine particles from candles, wood stoves, cooking and outdoor air. | below 10 µg/m³ | 10–25 | 25 or more |
| Humidity | Relative humidity. | 30–60 % | 25–30 or 60–70 % | below 25 or 70 % or more |
| Temperature | Indoor temperature. | 18–25 °C | outside that | – |
| Air pressure | Follows the weather. Changes can push radon out of the ground. | – | – | – |

These are common defaults. When you have set your own thresholds for a sensor in the Airthings app, the app uses yours (they are fetched once a day).

## Radon: what counts

- Radon is judged by the **annual average**. The Norwegian Radiation and Nuclear Safety Authority (DSA) recommends measures when the annual average is **100 Bq/m³** or more (the action level) and says it should always be below **200 Bq/m³** (the limit value). The limits are binding for schools, kindergartens and rented homes; for a home you own they are a recommendation.
- Measure in the **winter half-year** (mid-October to mid-April) for **at least two months**, in the rooms you use most, on the lowest floor you live on.
- The short-term value (an average of about the last 24 hours) swings a lot with weather, wind, air pressure and ventilation. One high short-term value is not a verdict. The long-term average the sensor shows is the best guide to the annual average while you measure.
- Typical measures: better ventilation, sealing cracks and openings towards the ground, and a radon sump with a fan. DSA's guide has more.

Sources: DSA, "Anbefalte grenser for radon" (dsa.no/radon/anbefalte-grenser-for-radon) and "Slik måler du radon" (dsa.no/radon/slik-maler-du-radon); radiation protection regulation § 6 (lovdata.no).

## How often data arrives

- With an **Airthings hub**, the sensors send values every 5 minutes, and radon every hour.
- **Without a hub**, values only reach Airthings when the Airthings phone app syncs with the sensor over Bluetooth, which means the values in this app can be hours or days old. "Measured … ago" on the sensor's page tells you.
- The app asks Airthings for the newest values of all your sensors at most every 5 minutes, the hourly history of each sensor at most once an hour, and the thresholds once a day. History is kept for two years.

## Good to know

- Airthings allows each API client a limited number of requests per hour. The app stays well below the limit and stops by itself before the limit is reached; if Airthings still refuses, it waits as long as Airthings asks.
- The client ID and secret are stored in the keychain on this Mac. Wrong values are not tried again until you save new ones.
- You can turn on a notification on the sensor's page for when the long-term radon average is 100 Bq/m³ or more (at most once a week while it lasts).
