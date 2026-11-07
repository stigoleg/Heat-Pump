# Changelog

New entries are in English. Entries up to 1.1.5 are in Norwegian.

## [2.0.0] – 2026-11-07

- **New name: Husly.** The app now covers more than the heat pump, so it is called Husly in every language. Nothing else changes for you: updates, your sign-in, history and the Claude setup carry over.
- **Several devices**: the app shows several devices side by side, also of different kinds and brands. With two or more, the sidebar has Home (an overview of every device, the forecast and Claude activity) and a group per device. With one heat pump the app looks as before.
- **Add Device**: one place to connect a service: Add Device… in the sidebar, File → Add Device… (⇧⌘N) or Settings → Devices. Choose MELCloud, Tibber or Airthings, sign in once, and every device on the account shows up. Settings → Devices lists your services and devices, where you can rename them or turn them off.
- **Energy meter (Tibber)**: your Tibber home as a device, with live power (with Tibber Pulse or Watty), today's use and cost, and history per hour and day. It uses the token you already saved for Tibber prices.
- **Indoor air (Airthings)**: Airthings sensors as devices, with radon (short- and long-term average), CO₂, VOC, particles, humidity, temperature and air pressure, levels and advice, history up to two years, and an optional notification when the long-term radon average reaches 100 Bq/m³. Read-only.
- **Menu bar**: turn on Settings → General → Menu bar to keep the heat pump in the menu bar. The title shows the mode, indoor temperature and power by default, and you choose what it shows and in which order (target and outdoor temperature, today's cost, the price now, a health warning). Click it for status, today's numbers, health and the controls (power, mode, temperature, fan and airflow direction), sent the same way as on Control. With several devices you pick which one it shows; an energy meter shows its power and today's use, an air quality sensor its readings with their levels. While it is on, the app keeps running without a Dock icon when you close the window.
- **Control**: only the active mode is coloured, so you see at a glance which one is on.
- **Claude**: with more than one device, Claude can list them and every tool takes an optional device. Claude can also read energy meters and air quality. With one heat pump the tools work as before.
- **Download as a disk image**: new versions come as a `.dmg` you open and drag to Applications.
- **Upgrading**: the database is upgraded once, with a backup next to it. If Claude Desktop is running during the update, restart it so the Claude helper uses the new version.

## [1.2.0] – 2026-11-06

- **English and Norwegian**: the app is now in English, with Norwegian bokmål as a full translation. It follows the macOS language (Norwegian on a Norwegian Mac, English otherwise), or you can choose under Settings → General → Language; the change takes effect after a restart. The app is called Heat Pump in English. The Claude helper follows the same choice: the approval window, health texts and knowledge documents come in the chosen language. Text already stored, such as reasons in the change log, stays in the language it was written in.
- **README** in English, with the Norwegian version in README.nb.md.

## [1.1.5] – 2026-11-05

- **Oppdateringer i appen**: appen ser etter nye versjoner på GitHub én gang i døgnet, laster dem ned og installerer dem når du avslutter appen. Du kan også velge «Installer og start på nytt». En nedlasting tas bare i bruk når sjekksummen stemmer og appen er signert og notarisert av samme utvikler. Innstillingene ligger under Innstillinger → Generelt → Oppdateringer, og menyen Varmepumpe har «Se etter oppdateringer …». Versjoner før 1.1.5 må oppdateres for hånd én gang.

## [1.1.0] – 2026-11-05

- **Prognose**: ny side med værvarsel for opptil ni dager, strømpriser fremover (kjente priser og et tydelig merket anslag for de neste dagene) og forventet forbruk og kostnad per dag.
- **Prisstyring**: senker temperaturen i dyre timer, aldri under en grense du velger og høyst et valgt antall timer per døgn. Virker bare mens appen kjører og Macen er på; når den er på, lever appen videre i menylinjen når vinduet lukkes, og temperaturen settes tilbake før Macen sover og når appen avsluttes.
- **Ukeplan**: ny side der MELCloud-ukeplanen kan leses og endres, med maler, kopiering av dager og bekreftelse før lagring. Planen kjører i MELCloud, også når Macen er av. Appen lagrer ikke over endringer gjort i MELCloud-appen i mellomtiden.
- **Fastvare**: oppdateringen av Wi-Fi-modulen kan startes og følges under Helse → Fastvare, og av Claude etter godkjenning på Macen.
- **Sted for værvarsel**: søk etter adresse eller sted, eller klikk i kartet. Nytt sted gir nytt varsel innen ti minutter.
- **Smale vinduer**: alle sider tilpasser seg vindusbredden, og vinduet kan gjøres smalere enn før.
- **Nøkkelringen**: appen og Claude-hjelperen deler tilgangen til innloggingen, så macOS slutter å spørre om passordet ved vanlig bruk. Første oppstart flytter lagrede innlogginger én gang.

## [1.0.0] – 2026-11-05

Første versjon.

- **Oversikt** med termostatring, effekt, dagens forbruk og kostnad, strømpris nå, helse og værvarsel.
- **Kontroll** av av/på, modus, temperatur (glidebryter og stepper), vifte og luftretning. Endringer sendes automatisk og samlet.
- **Historikk** for temperatur, energi og kostnad, drift og effekt, med periodevalg fra 24 timer til ett år.
- **Strømpris**: Norgespris, spotpris via Tibber eller via hvakosterstrommen.no, nettleie (Elvia) og strømstøtte.
- **Lokal tilkobling** (bare lesing) til Wi-Fi-modulen for effekt, kompressor, avriming og nøyaktig strømmåler.
- **Helse** med feillogg, vedlikeholdspåminnelser og regler for korte sykluser, forbruk, avriming, Wi-Fi og fastvare.
- **Borte hjemmefra**: frostsikring og feriemodus via MELCloud.
- **Værvarsel** fra MET Norway og anslag for morgendagens forbruk og kostnad.
- **Husets strømforbruk** fra Tibber og varmepumpens andel.
- **Claude-tilkobling** gjennom en innebygd MCP-server. Alle endringer fra Claude må godkjennes på Macen.
- Lys og mørk modus.
