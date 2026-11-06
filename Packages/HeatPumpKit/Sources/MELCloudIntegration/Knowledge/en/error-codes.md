# Error codes

## Important caveat

Mitsubishi has no public error code table for the MSZ-RW series as it appears in MELCloud. We do not have the service manual for MSZ-RW (OBH902C). The tables below come from the service manual for the related MSZ-LN series (OBH766H) and from observations in MELCloud. How MELCloud's `ErrorCode` relates to the blink codes is unknown. Use the explanations as a pointer, and let the dealer make the diagnosis.

## MELCloud

- `ErrorCode` 8000 means “no error” on air-to-air units (observed in several open integrations).
- `HasError` = true means the unit is reporting an error right now.
- The error log in MELCloud gives a text (`ErrorMessage`) with start and end time. That text comes from Mitsubishi and is the best source we have.
- Some 4-digit codes are known from other Mitsubishi series (for example 5101 room sensor, 5102 pipe sensor, 6840 indoor/outdoor communication). It is **not** confirmed that they mean the same on MSZ-RW.

## When the operation lamp blinks (MSZ-LN §10-4, related model)

The operation lamp (POWER) on the indoor unit blinks a number of times, then stays off for 2.5 seconds, and repeats the pattern.

| Blinks | What it concerns | Explanation |
|---|---|---|
| Blinks steadily (0.5 s on/off) | Miswiring or serial signal | The indoor unit receives no signal from the outdoor unit for 6 minutes. |
| 2 | Indoor unit temperature sensor | Pipe sensor or room sensor is short-circuited or open. |
| 3 | Indoor unit fan motor | The fan motor gives no speed signal. |
| 4 | Indoor unit control board | The board cannot read its memory. |
| 5 | Outdoor unit power system | The compressor has stopped because of overcurrent or a start-up failure three times in a row. |
| 6 | Outdoor unit temperature sensors | A sensor is short-circuited or open while the compressor runs. |
| 7 | Outdoor unit control board | The board cannot read its memory. |
| 14 or more | Other fault | Among other things sensors, valves or the stop valve. Do not start it again until it has been repaired. |

The service manual also has a “failure memory” function (§10-2.4) that the technician can use. There, 1 blink means room sensor, 2 blinks pipe sensor, 3 blinks serial signal from the outdoor unit, 11 blinks fan motor and 12 blinks control board. §10-2.5 in the same manual is the failure memory table for the air purifier (AIR PURIFYING) and the i-see sensor, not for the outdoor unit. The failure memory table for the outdoor unit is in the service manual for the outdoor unit, which we do not have.

## What to do

1. Count the number of blinks for at least two rounds.
2. Note the time and any error text from MELCloud.
3. Turn off the heat pump. The owner's manual says to stop using it and contact the dealer when the operation lamp blinks.
