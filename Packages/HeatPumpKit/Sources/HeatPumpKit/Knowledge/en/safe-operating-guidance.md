# Safe and sensible use

This is practical, well-established advice. Where something is uncertain for this particular model, it says “uncertain”.

## Temperature and operation

- **Keep the temperature steady.** An air-to-air heat pump is most efficient when it runs steadily. Frequent on/off and big jumps in the target temperature give higher consumption and more wear.
- **Lower rather than turn off.** If you go away for a few days, lower the temperature a couple of degrees instead of turning it off. This saves the most in cold weather.
- **Do not turn it up high to get heat faster.** The heat pump does not heat faster because you set 28 °C. It just runs longer and uses more electricity.
- **Small adjustments.** One or two degrees at a time is enough. Wait at least an hour and look at the result.
- **Choose the right mode.** Heat in winter. “Auto” can switch between heating and cooling and is rarely best in a Norwegian winter.

## Airflow

- Do not block the indoor unit with furniture, curtains or shelves. The air must be able to circulate freely.
- When heating, the vane should point downwards or be set to auto, so the warm air reaches the floor.
- Keep doors open to rooms you want to heat.

## The outdoor unit in winter

- Keep the outdoor unit free of snow and ice, especially underneath and in front. It needs air and must be able to drain meltwater.
- Clear snow around the outdoor unit after snowfall. Do not chip ice off the fins with hard tools.
- **Defrosting is normal.** In winter the heat pump stops now and then for up to 10 minutes to melt ice. The outdoor unit may then steam (“white smoke”) and drip. This is not a fault.
- At very low outdoor temperatures the heating capacity drops. The unit is guaranteed to heat down to −30 °C, but with lower capacity.

## Cabins and frost protection

- Many Mitsubishi models have a separate “10 °C heating” function for frost protection. **Uncertain:** the owner's manual for MSZ-RW does not mention such a function, and the lowest target temperature in MELCloud depends on the unit. Check the minimum value in the app before relying on low background heat.
- Do not use the heat pump as the only frost protection if a power or network outage could cause damage. It starts again automatically after a power outage (auto restart), but you are not told if it has stopped.
- **Frost protection in MELCloud** (in the app: “Away”): when it is on, the heat pump keeps the room between a lowest and highest temperature even if it is otherwise off. The lowest can be 4–14 °C, the highest 6–16 °C, and the highest must be at least 2 °C above the lowest. 8–12 °C is a common choice for a house or cabin that stands empty.
- **Holiday mode**: choose a start and end. During the period the heat pump may stand off, and then frost protection is what keeps the house from getting too cold. The app and Claude therefore do not turn on holiday mode until frost protection is on, and do not turn off frost protection while holiday mode is on. A lowest temperature of 8 °C or more is recommended.
- **Times in holiday mode**: how MELCloud stores the times (UTC or local time) is not confirmed. After a change, the app shows the times MELCloud reads back next to what you chose; if they differ (for example shifted by one hour), check in the MELCloud app.
- Both are bigger changes than adjusting the temperature, so the app asks you to confirm, and Claude must get approval in the window on the Mac. The functions have not been tested against this account yet: make the first change yourself in the app and check in the MELCloud app that it was registered.
- **Weekly schedule**: if the weekly schedule in MELCloud is turned on, the heat pump may change temperature or turn itself on and off according to the schedule. The schedule lives in MELCloud and runs even when the Mac is off, and the same schedule is shown in the MELCloud app. A change you make in Control (or that Claude makes) lasts only until the next event in the schedule. The schedule is created and changed on the “Weekly schedule” page in the app, and every save counts as one of the 12 sends per hour. Claude can read the schedule, but not change it. Saving has not been tried against this account yet: check in the MELCloud app that the schedule looks right after the first save.

## Humidity and odor

- Clean the air filter every 2 weeks. Dirty filters cause condensation and can lead to mold.
- If it smells odd, check the filters first.

## Electricity price

- When electricity is expensive for a few hours (typically morning and afternoon), you can raise the target temperature 0.5–1 °C a couple of hours before, and lower it by the same amount while the price is high. The house stores some heat.
- Avoid big jumps (more than 2 °C) and turning the heat pump off and on to save money. Frequent on/off wears the compressor, and it costs more to heat a cooled-down house back up.
- With Norgespris (fixed price) the price is the same all day; then you save the most with a steady, slightly lower temperature. The grid tariff is still lower at night and on weekends.
- The cost the app shows is electricity + the grid tariff energy charge − the electricity subsidy. The capacity charge (fixed charge) is not included, because it depends on the whole household's peak consumption.
- Price level: Tibber marks every hour from “very cheap” to “very expensive” relative to the average of the last few days. With other spot sources the app calculates the same against the average of the last 72 hours. With Norgespris the price is fixed, so no level is shown.
- **Price estimate** (the “Forecast” page): for the days after the published prices, the app shows an estimate based on how the price has varied through the day over the last four weeks and the level over the last week, adjusted for the weather forecast when the price has followed the temperature. It is uncertain and not a price; real prices for tomorrow arrive around 13:00. Always call it an estimate.
- **Price control** (the “Forecast” page): when the user has turned it on, the app lowers the target temperature in expensive hours (by default 1 °C, in very expensive hours 2 °C, never below a lowest temperature, by default 18 °C, and at most a chosen number of hours per day, by default 8, the most expensive ones) and sets it back afterwards; optionally +1 °C in a couple of cheap hours before. It uses only published prices, works only in heat mode, never changes on/off or mode, and takes precedence over holiday mode and events in the weekly schedule. It only works while the app is running and the Mac is on and awake. If the user changes the temperature themselves, price control pauses until the next step. The changes are logged with the source “Price control” and count toward the 12 sends per hour. Claude can read the status and plan, but cannot turn it on or off or change it. If price control is on, Claude should not also move the temperature up and down according to price.

## Weather forecast and pre-heating

The app fetches a weather forecast from MET Norway (yr.no) for the house, at most once an hour. Weather data: MET Norway, CC BY 4.0.

- **Pre-heating before cold and expensive hours**: if a cold period comes at the same time as high prices, you can raise the target temperature by at most 1 °C two to three hours before, and set it back when the period starts or is over. Small steps are enough; the house holds its heat for a while.
- **Avoid**: turning it far up and down several times a day, turning the heat pump off to save money, and big jumps. Frequent changes cause hard starts and wear the compressor, and a cooled-down house costs more to heat back up.
- **Wind and humidity**: strong wind increases heat loss; damp weather around 0 °C causes more defrosting. Both can increase consumption a little without anything being wrong.
- **Estimate for tomorrow**: the app compares consumption with how cold it has been (degree days with a base of 17 °C) on at least 10 of the last 45 days, and uses tomorrow's forecast and prices. It is a rough estimate with an uncertainty range, not a promise.

## Local readings (power and compressor)

When the local connection is turned on in the app, the app reads the Wi-Fi adapter directly on the home network (read only, never control). This gives:

- **Power (W)**: what the whole heat pump draws right now. Around 4 W means the compressor is idle (only electronics and the fan at rest). While heating, 300–1200 W is common for this size; more when it is cold outside or when it heats up a cold room.
- **Compressor (Hz)**: how hard the compressor works. 0 Hz means it is idle. A low, steady frequency over a long time is the most efficient.
- **Energy meter**: a counter in the pump with 0.1 kWh resolution. It gives accurate consumption per hour, so the cost is exact (not an estimate) for days the app has measured in full.
- **Compressor starts per hour**: one to three starts per hour is normal. Many short runs (four or more per hour over several hours) are called short cycling and wear the compressor. See “Maintenance” for what you can do.
- **What it is doing now**: “Heating”, “Resting (target temperature reached)”, “Preheating” (warming up before the fan runs at full speed, so it does not blow cold air) or “Defrosting”. During defrosting the outdoor unit melts away ice; the indoor unit then blows little or cold air for a few minutes. This is normal and should not be stopped. Do not change settings because of a defrost.
- **Total running time**: the indoor unit counts minutes itself. The figure is probably the total running time since the unit was put into service, but its meaning is not confirmed by Mitsubishi.

Advice for control based on power:

- Avoid turning the target temperature far up and down. Every jump causes a hard start with high power.
- If the power is high for a long time even though it is not cold outside, check the air filter and the outdoor unit before changing settings.
- The endpoint in the adapter is unofficial and may stop working after a firmware update. Everything else then works through MELCloud as before.

## Firmware update

MELCloud reports when there is new firmware for the Wi-Fi adapter. The app shows it under Health → Firmware, where you can start the update and follow it. Claude can also start it, but only after you have approved it in the dialog on the Mac.

- **Cannot be undone**: a firmware update cannot be rolled back once it has started.
- **Power and Wi-Fi**: the heat pump must stay powered and have good Wi-Fi the whole time. Do not disconnect it from the mains and do not use the remote control while the update is running (MELCloud gives the same warning).
- **Time**: the update can take a while. The Wi-Fi adapter downloads files and restarts; during that time the heat pump cannot be controlled from the app or MELCloud.
- **Owner only**: only the account that owns the unit in MELCloud can start the update, and only when the unit is connected.
- **Canceling**: while the update is waiting for the unit or downloading, it can be canceled in the app.
- **Not urgent**: preferably start it when you are at home and do not need to change anything for the next hour.

## Safety

- R32 is a flammable refrigerant. If you suspect a leak: turn it off, ventilate, no open flame, call the dealer.
- Do not put fingers or objects into the air inlet or outlet.
- Do not climb on or put things on the outdoor unit.

## About changes through the app and Claude

- All changes to the heat pump require your approval.
- The app allows at most 12 changes per hour and fetches status at most once a minute, so MELCloud does not block the account for too much traffic.
