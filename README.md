<p align="center">
  <img src="docs/icon.png" width="128" alt="Varmepumpe-ikonet">
</p>

<h1 align="center">Varmepumpe</h1>

<p align="center">
  En Mac-app for styring og helseovervåking av en Mitsubishi Electric-varmepumpe (luft-til-luft) via MELCloud, med Claude som rådgiver.
</p>

<p align="center">
  <a href="https://github.com/stigoleg/Heat-Pump/actions/workflows/ci.yml"><img src="https://github.com/stigoleg/Heat-Pump/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/stigoleg/Heat-Pump/releases/latest"><img src="https://img.shields.io/github/v/release/stigoleg/Heat-Pump" alt="Siste versjon"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-blue" alt="macOS 26+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/lisens-GPL--3.0-green" alt="GPL-3.0"></a>
</p>

<p align="center">
  <img src="docs/screenshots/oversikt-lys.png" width="49%" alt="Oversikt i lys modus">
  <img src="docs/screenshots/oversikt-mork.png" width="49%" alt="Oversikt i mørk modus">
</p>

Den offisielle MELCloud-appen gir lite oversikt. Varmepumpe samler status, styring, historikk, strømkostnad og helse i ett ryddig vindu, skrevet for folk som ikke kan noe om varmepumper. Claude kan lese alt appen ser og foreslå tiltak, men hver endring på pumpen må godkjennes av deg.

Laget og testet for en **MSZ-RW25VG** med innebygd Wi-Fi. Andre luft-til-luft-modeller i klassisk MELCloud bør også virke, men er ikke testet. Appen er på norsk.

## Innhold

- [Funksjoner](#funksjoner)
- [Skjermbilder](#skjermbilder)
- [Installer](#installer)
- [Kom i gang](#kom-i-gang)
- [Koble til Claude](#koble-til-claude)
- [Slik virker det](#slik-virker-det)
- [Sikkerhet og personvern](#sikkerhet-og-personvern)
- [Utvikling](#utvikling)
- [Lage en ny versjon](#lage-en-ny-versjon)
- [Lisens](#lisens)

## Funksjoner

- **Oversikt** – termostatring du kan dra i, innetemperatur, ute, effekt, dagens forbruk og kostnad, strømpris nå, hva pumpen gjør (varmer, hviler, avriser) og værvarsel for de neste 48 timene.
- **Kontroll** – av/på, modus, temperatur (glidebryter og stepper), viftehastighet og luftretning. Endringer sendes automatisk et par sekunder etter at du har stilt inn. Ukeplanen fra MELCloud vises nederst.
- **Historikk** – temperatur, energi og kostnad, drift og effekt, for 24 timer, 7 dager, 30 dager eller ett år.
- **Strømkostnad** – Norgespris, spotpris via Tibber eller spotpris fra hvakosterstrommen.no, med nettleie og strømstøtte. Prisene farges fra svært billig til svært dyr.
- **Helse** – feillogg med forklaringer, påminnelser om filterrengjøring og varsler om korte sykluser, uvanlig høyt forbruk, hyppig avriming, svakt Wi-Fi og fastvare. Fastvareoppdateringer av Wi-Fi-modulen kan startes og følges her.
- **Borte hjemmefra** – frostsikring og feriemodus.
- **Lokal tilkobling** – leser effekt, kompressor, avriming og en nøyaktig strømmåler direkte fra Wi-Fi-modulen på hjemmenettet. Bare lesing.
- **Husets strømforbruk** – fra Tibber, med varmepumpens andel.
- **Claude** – innebygd MCP-server med 22 verktøy, en helsesjekk og kunnskapsdokumenter om vedlikehold og feilkoder.
- **Lys og mørk modus** – med ett klikk i verktøylinjen eller ⌘⇧L.

## Skjermbilder

| Kontroll | Helse |
|---|---|
| <img src="docs/screenshots/kontroll.png" alt="Kontroll"> | <img src="docs/screenshots/helse.png" alt="Helse"> |

| Historikk: temperatur | Historikk: energi og kostnad |
|---|---|
| <img src="docs/screenshots/historikk-temperatur.png" alt="Temperaturhistorikk"> | <img src="docs/screenshots/historikk-energi.png" alt="Energi og kostnad"> |

| Historikk: effekt | Historikk: drift |
|---|---|
| <img src="docs/screenshots/historikk-effekt.png" alt="Effekt"> | <img src="docs/screenshots/historikk-drift.png" alt="Drift"> |

| Borte hjemmefra | Innstillinger: strømpris |
|---|---|
| <img src="docs/screenshots/borte.png" alt="Borte hjemmefra"> | <img src="docs/screenshots/innstillinger-strompris.png" alt="Strømpris"> |

Skjermbildene er tatt i demo-modus med simulerte data.

## Installer

1. Last ned `Varmepumpe-<versjon>.zip` fra [siste versjon](https://github.com/stigoleg/Heat-Pump/releases/latest).
2. Pakk ut og flytt `Varmepumpe.app` til Programmer.
3. Åpne appen. Den er signert med Developer ID og notarisert av Apple, så den åpnes uten advarsel.

Krever macOS 26 eller nyere, på Apple Silicon eller Intel.

## Kom i gang

1. **Logg inn** med samme e-post og passord som i MELCloud-appen. Innloggingen lagres i nøkkelringen på Macen.
2. **Velg strømavtale** under Innstillinger → Strømpris: Norgespris, spotpris via Tibber (krever en [personlig nøkkel](https://developer.tibber.com/settings/access-token)) eller spotpris uten Tibber. Nettleien er forhåndsutfylt med Elvias satser og kan endres.
3. **Slå på lokal tilkobling** (valgfritt) under Innstillinger → Lokal tilkobling → **Finn automatisk** → **Test**. macOS spør om tilgang til lokalt nettverk; svar Tillat.
4. **Sted for værvarsel** hentes fra MELCloud. Mangler det, legger du det inn under Innstillinger → Vær.

Appen henter data bare mens vinduet er åpent, og avsluttes når du lukker det. Claude kan likevel lese når appen er lukket.

## Koble til Claude

Innstillinger → Claude viser kommandoen med riktig sti og en kopier-knapp:

```sh
claude mcp add varmepumpe --scope user -- "/Applications/Varmepumpe.app/Contents/Helpers/varmepumpe-mcp"
```

Start Claude Code på nytt og spør for eksempel «Kjør helsesjekk på varmepumpa». Første gang spør macOS om MCP-serveren får lese innloggingen i nøkkelringen; velg **Tillat alltid**.

Når Claude vil endre noe, viser Macen et eget vindu, «Claude vil endre varmepumpen», med endringen og Claudes begrunnelse. Endringen sendes bare hvis du trykker **Godkjenn**. Avvis, Esc eller ingen svar innen to minutter stopper den. Dette gjelder uansett tillatelsesmodus i Claude Code. Legg likevel ikke `set_*`-verktøyene eller `start_firmware_update` i listen over verktøy som er tillatt uten å spørre.

<details>
<summary>Verktøy og ressurser for Claude</summary>

- **Lesing:** `get_status`, `get_live_status`, `get_health_report`, `get_error_log`, `get_history`, `get_energy`, `get_prices`, `get_forecast`, `get_house_consumption`, `get_maintenance_status`, `get_away_settings`, `get_firmware_status`, `get_change_log`, `get_device_info`, `refresh`
- **Endring (med godkjenning):** `set_power`, `set_mode`, `set_temperature`, `set_fan_speed`, `set_vanes`, `set_frost_protection`, `set_holiday_mode`, `start_firmware_update`, `record_maintenance`
- **Prompt:** `helsesjekk` – full gjennomgang med prioritert oppsummering
- **Ressurser:** `varmepumpe://knowledge/…` – varmepumpeprofil, vedlikehold, feilkoder, når du bør ringe forhandleren og råd om trygg drift

</details>

## Slik virker det

```
Varmepumpe.app (SwiftUI)          varmepumpe-mcp (stdio, i Contents/Helpers)
        \                                  /
         HeatPumpKit (Swift-pakke)
           HeatPumpService – hurtigbuffer, grenser for trafikk, revisjonslogg
           MELCloud-klient (styring) · lokal klient (bare lesing) · Tibber · MET
           HistoryStore    – SQLite i ~/Library/Application Support/Varmepumpe/
           HealthEngine    – regelbasert helsevurdering
           Knowledge/*.md  – kunnskap som appen og Claude bruker
```

Appen og MCP-serveren deler én database, slik at det finnes én hurtigbuffer, én historikk og én felles grense for trafikk mot MELCloud, uansett hvem som spør.

<details>
<summary><b>Strømpris og kostnad</b></summary>

- **Norgespris:** fast pris per kWh (standard 50 øre inkl. mva., 40 øre i NO4). Ingen strømstøtte.
- **Spotpris via Tibber:** timepriser fra Tibber med din personlige nøkkel.
- **Spotpris uten Tibber:** timepriser fra hvakosterstrommen.no for valgt prisområde, med påslaget fra strømselskapet. Mva. legges til (ikke i NO4).

Nettleiens energiledd er forhåndsutfylt med Elvias satser for husholdninger fra 1. juli 2026: dag 46,40 øre og natt/helg/helligdag 31,40 øre, inkl. avgifter og mva. Kapasitetsleddet er ikke med, fordi det avhenger av hele husets høyeste forbruk. For spotavtaler trekkes strømstøtten fra: staten dekker 90 % av timeprisen over 96,25 øre/kWh inkl. mva. (2026).

Kostnad = forbruk × (strøm + nettleie − støtte). Med lokal tilkobling brukes målt forbruk per time. Ellers prises døgnets forbruk med døgnets snittpris, og beløpet merkes «anslag». Priser hentes høyst én gang i timen.

</details>

<details>
<summary><b>Lokal tilkobling</b></summary>

Wi-Fi-modulen svarer også direkte på hjemmenettet. Appen kan lese den der i tillegg til MELCloud. Det gir effekt i watt, kompressorfrekvens og -starter, avriming, raskere temperaturer, feilkoden fra innedelen og en strømmåler med 0,1 kWh oppløsning.

- **Bare lesing, håndhevet i koden.** Klienten har én operasjon: en statusforespørsel (`<CSV></CSV>` til `/smart`). Den sender aldri `CONNECT`-innstillingen (som kan koble modulen fra MELCloud), kommandoer, omstart eller admin-forespørsler. All styring går via MELCloud.
- Bare private IPv4-adresser, ingen omdirigeringer, og bare svar fra adressen den spurte.
- Leser bare når Macen er på samme nett som pumpen. Borte fra hjemmet står lokal lesing på pause.
- Høyst én forespørsel per 20 sekunder, felles for appen og Claude, med lengre pauser etter feil.
- MAC-adresse og serienummer fjernes rett etter dekryptering og lagres eller vises aldri.
- Endepunktet er uoffisielt og kan slutte å virke etter en fastvareoppdatering. Da virker resten av appen som før.
- Av som standard.

Helsereglene for korte sykluser, forbruk per grad og avriming bygger på disse målingene. Grensene er tommelfingerregler og står i kunnskapsdokumentet om vedlikehold.

</details>

<details>
<summary><b>Borte hjemmefra</b></summary>

- **Frostsikring** holder rommet mellom laveste (4–14 °C) og høyeste (6–16 °C) temperatur når pumpen ellers står av.
- **Feriemodus** gjelder fra og til en gitt tid. Fordi pumpen kan stå av i perioden, kan feriemodus bare slås på når frostsikringen er på, og frostsikringen kan ikke slås av mens feriemodus gjelder.

Hver endring bekreftes i et eget vindu og logges. Etter en endring viser siden både det som ble sendt og det MELCloud leser tilbake. Sammenlign første gang med MELCloud-appen.

</details>

<details>
<summary><b>Værvarsel og anslag</b></summary>

Timevarsel fra [MET Norway](https://api.met.no/) (samme kilde som yr.no), lisens CC BY 4.0. Posisjonen rundes av til omtrent 1 km før den sendes, og vises aldri. Appen henter høyst én gang i timen og respekterer METs hurtigbufferregler. Du kan oppgi en kontakt-e-post for MET under Innstillinger → Vær; den fylles aldri inn automatisk.

Anslaget for morgendagens forbruk og kostnad bygger på sammenhengen mellom forbruk og graddager de siste 45 dagene, og vises først når det finnes minst 10 dager med data.

</details>

<details>
<summary><b>Endringer sendes automatisk</b></summary>

Endringer i Kontroll og på termostaten sendes omtrent 2 sekunder etter siste justering. Flere justeringer samles i én sending, og stiller du tilbake til nåværende verdi, sendes ingenting. Merket øverst viser «Endret…», «Sender…», «Sendt – venter på pumpen», «Bekreftet» eller feilen. Hver sending inneholder hele innstillingsobjektet fra MELCloud, slik at felt du ikke endret, beholder verdien.

</details>

## Sikkerhet og personvern

- **Claude leser fritt, men endrer bare med godkjenning** i vinduet på Macen. Alle endringer logges med kilde (app eller Claude), gammel og ny verdi, begrunnelse og resultat, og vises under Claude-aktivitet.
- **Høflig mot MELCloud.** Status hentes høyst hvert minutt og gjenbrukes i 10 minutter. Høyst 12 endringer per time med minst 5 sekunder mellom. Ved «for mye trafikk» (HTTP 429) stopper all trafikk til sperren er over, og ved avvist passord stopper all henting til ny innlogging er lagret.
- **Hemmeligheter** (MELCloud-innlogging, økt og Tibber-nøkkel) ligger i macOS-nøkkelringen, aldri i klartekst på disk.
- **Andre tjenester:** MET Norway (vær), Tibber (priser og forbruk, bare med nøkkel) og hvakosterstrommen.no (priser). Ingen analyse eller sporing.
- **Ingen offisiell feilkodetabell** for MSZ-RW er offentlig. Forklaringene av feilkoder er derfor merket med usikkerhet.

Varmepumpe er ikke laget av eller tilknyttet Mitsubishi Electric. MELCloud er et varemerke for Mitsubishi Electric.

## Utvikling

Krever Xcode 27 (Swift 6.4), macOS 26 og [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). `project.yml` er kilden; `.xcodeproj` lages og sjekkes ikke inn.

```sh
make build     # signert Release-bygg i build/DerivedData
make test      # enhetstestene i HeatPumpKit
make install   # bygg og kopier til /Applications (avslutt appen først)
make demo      # appen med simulerte data og egen database i build/demo/
make check     # tester og Debug-bygg
make clean
```

Lokale bygg signeres med «Apple Development» (team `49P95434EE`), med hardened runtime og uten App Sandbox, slik at appen og MCP-serveren deler database og nøkkelring.

**Demo-modus** (`make demo`, eller `VARMEPUMPE_BACKEND=mock`) gir en simulert varmepumpe med vinterdata, lokal Wi-Fi-modul, priser, vær, husets forbruk og av og til en feil. Ingen kall går til MELCloud.

**Kunnskapsdokumentene** i `Packages/HeatPumpKit/Sources/HeatPumpKit/Knowledge/*.md` kompileres inn i koden. Kjør `python3 Packages/HeatPumpKit/scripts/generate-knowledge.py` etter endringer; en test feiler hvis det er glemt.

**Appikonet** lages fra `App/Icon/AppIcon.svg` med `App/Icon/render.sh` (krever `brew install librsvg`).

<details>
<summary>Miljøvariabler</summary>

| Variabel | Betydning |
|---|---|
| `VARMEPUMPE_BACKEND=mock` | Simulert varmepumpe |
| `VARMEPUMPE_DB_PATH` | Sti til SQLite-databasen |
| `MELCLOUD_EMAIL`, `MELCLOUD_PASSWORD` | Kun utvikling: innlogging uten nøkkelring |
| `VARMEPUMPE_APPROVAL=auto-approve` / `auto-reject` | Kun tester: svarer i stedet for godkjenningsvinduet. Virker bare med `VARMEPUMPE_BACKEND=mock`. |
| `VARMEPUMPE_SCREEN` | Startskjerm: overview, control, history, away, health, activity |
| `VARMEPUMPE_HISTORY_TAB` | Startfane i Historikk: temperature, energy, energy-kr, operation, power |
| `VARMEPUMPE_HISTORY_RANGE` | Startperiode i Historikk: day, week, month, year |
| `VARMEPUMPE_SCROLL_TO` | Ruller til en seksjon etter tre sekunder (skjermbilder) |
| `VARMEPUMPE_APPEARANCE` | `light`, `dark` eller `system`, uten å lagre valget |
| `VARMEPUMPE_SETTINGS_TAB` | Åpner Innstillinger på fanen: generelt, konto, strompris, lokal, vaer, claude, data |
| `VARMEPUMPE_MOCK_CYCLING=short` | Simulert kompressor går i korte runder |

</details>

## Lage en ny versjon

Versjoner bygges, signeres med Developer ID, notariseres og publiseres av GitHub Actions ([`release.yml`](.github/workflows/release.yml)) når en tag som `v1.2.3` pushes:

```sh
# Oppdater CHANGELOG.md og versjonen i project.yml (MARKETING_VERSION), commit, så:
git tag v1.2.3
git push origin main v1.2.3
```

Arbeidsflyten kjører testene, bygger en universell app (Apple Silicon og Intel), notariserer og stifter den, og legger `Varmepumpe-1.2.3.zip` med SHA-256 under Releases. Teksten hentes fra CHANGELOG.md.

Den trenger disse hemmelighetene i repoet:

| Hemmelighet | Innhold |
|---|---|
| `MACOS_CERTIFICATE_P12` | base64 av eksportert «Developer ID Application»-sertifikat med nøkkel (.p12) |
| `MACOS_CERTIFICATE_PASSWORD` | passordet til .p12-filen |
| `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | App Store Connect API-nøkkel (base64 av .p8), eller: |
| `NOTARY_APPLE_ID`, `NOTARY_PASSWORD` | Apple-ID og app-spesifikt passord |

Lokalt gjør `make release VERSION=1.2.3 NOTARY_PROFILE=<profil>` det samme, med en profil lagret med `xcrun notarytool store-credentials`.

## Lisens

[GPL-3.0](LICENSE). Du kan bruke, endre og dele programmet, men endrede versjoner som deles må også ha åpen kildekode under samme lisens.
