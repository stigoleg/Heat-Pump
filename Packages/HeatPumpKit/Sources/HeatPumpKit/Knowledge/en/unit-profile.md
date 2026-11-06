# Unit profile: Mitsubishi Electric MSZ-RW25VG

These are facts about the heat pump, taken from the rating plate and the owner's manual. Serial number, MAC address, Wi-Fi name (SSID) and Wi-Fi key are deliberately left out.

## Model

| Field | Value |
|---|---|
| Indoor unit | MSZ-RW25VG (service reference MSZ-RW25VG-SC1) |
| Type | Air-to-air heat pump, wall-mounted indoor unit |
| Manufactured | April 2022 |
| Refrigerant | R32 |
| Voltage | 230 V |
| Indoor unit protection rating | IP20 (indoor use only, not protected against splashing water) |
| Indoor unit weight | 14.5 kg |
| Indoor unit power input | 21 W (fan and controls) |
| Indoor unit rated current | 0.21 A |
| Maximum allowable pressure (HP PS) | 4.17 MPa |
| Wi-Fi adapter | Built in (MB507IF according to the owner's manual), connected to MELCloud (Classic) |

## Operating range (from the owner's manual)

- Heating: the guaranteed operating range is −30 °C to 24 °C outdoors (dry bulb) and 20–27 °C indoors. The rated capacity is measured at 20 °C indoors and 7 °C outdoors.
- Cooling: −10 °C to 46 °C outdoors.
- At very low outdoor temperatures the heating capacity drops. This is normal.

## MELCloud

- The unit uses MELCloud Classic (app.melcloud.com), not MELCloud Home.
- MELCloud reports room temperature, target temperature, mode, fan, vanes, Wi-Fi signal (dBm) and error status.
- MELCloud has no reminder of its own for filter cleaning. It has to be recorded manually in the app.

## Security note about the Wi-Fi adapter

Wi-Fi adapters in the same group as MSZ-RW25VG-SC1 are affected by vulnerability CVE-2026-5667 (hard-coded password for the adapter's own access point) for adapter version 42.00 and earlier. The flaw is fixed in version 43.00. The vulnerability only matters when the unit is not connected to a router (setup mode). Check the firmware version in MELCloud or with the dealer, and keep the unit connected to the router. The app shows the adapter's firmware version under Settings → Account and Health → Firmware (MELCloud reports for example 34000, which means version 34.00). Updating is recommended, but not urgent as long as the unit is connected to the home network. The update can be started under Health → Firmware, by Claude after you have approved it in the dialog, or in the MELCloud app. See “Firmware update” in the safe operating guidance before you start.
