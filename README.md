# Varmepumpe

Styring og helseovervåking av en Mitsubishi Electric MSZ-RW25VG (luft-til-luft) via klassisk MELCloud, for macOS. Prosjektet har to deler:

- **Varmepumpe.app** (`App/`): Mac-appen med oversikt, kontroll, historikk, helse, Claude-aktivitet og innstillinger.
- **HeatPumpKit** (`Packages/HeatPumpKit`): felles Swift-bibliotek med MELCloud-klient, lokal historikk i SQLite, helsemotor og kunnskapsdokumenter. All logikk ligger her; appen er bare visning.
- **varmepumpe-mcp**: en MCP-server (stdio) som lar Claude lese status og historikk og foreslå endringer. Den bygges inn i appen under `Varmepumpe.app/Contents/Helpers/`.

## Bygg og test

Krever Xcode 27 / Swift 6.4, macOS 26 og [XcodeGen](https://github.com/yonaskolb/XcodeGen). `project.yml` er kilden; `.xcodeproj` lages og sjekkes ikke inn.

```sh
xcodegen generate
xcodebuild -scheme Varmepumpe -configuration Debug -derivedDataPath build/DerivedData build
# Appen: build/DerivedData/Build/Products/Debug/Varmepumpe.app

cd Packages/HeatPumpKit
swift build
swift test
```

Appen signeres med «Apple Development»-sertifikatet (team `49P95434EE`, som er teamet i sertifikatet), med hardened runtime og uten App Sandbox, slik at appen og MCP-serveren deler database og nøkkelring.

Kunnskapsdokumentene i `Packages/HeatPumpKit/Sources/HeatPumpKit/Knowledge/*.md` kompileres inn i koden. Etter endringer i dem:

```sh
python3 Packages/HeatPumpKit/scripts/generate-knowledge.py
```

En test feiler hvis dette er glemt.

## Installer

Kopier `Varmepumpe.app` til Programmer-mappen. Første gang uten innlogging viser appen en velkomstside der du logger inn på MELCloud.

## Kjør med simulert varmepumpe (demo)

```sh
open -n --env VARMEPUMPE_BACKEND=mock --env VARMEPUMPE_DB_PATH=/tmp/varmepumpe-demo.sqlite \
  build/DerivedData/Build/Products/Debug/Varmepumpe.app

VARMEPUMPE_BACKEND=mock VARMEPUMPE_DB_PATH=/tmp/varmepumpe-demo.sqlite \
  build/DerivedData/Build/Products/Debug/Varmepumpe.app/Contents/Helpers/varmepumpe-mcp
```

Appen viser merket «Demo-data». Den simulerte varmepumpen gir realistiske vinterdata og en feil i feilloggen omtrent hver 17. dag.

## Koble til Claude Code

Innstillinger → Claude i appen viser den nøyaktige kommandoen med riktig sti, med en kopier-knapp. For en app i Programmer-mappen:

```sh
claude mcp add varmepumpe --scope user -- "/Applications/Varmepumpe.app/Contents/Helpers/varmepumpe-mcp"
```

Ikke legg `set_*`-verktøyene til i Claudes liste over verktøy som er tillatt uten å spørre.

Prompten `helsesjekk` gir en full helsesjekk med prioritert oppsummering. Kunnskapsdokumentene er tilgjengelige som ressurser under `varmepumpe://knowledge/…`.

## Innlogging

E-post og passord legges inn i appen (Innstillinger → Konto, eller velkomstsiden). De lagres i macOS-nøkkelringen (tjeneste `com.stigole.varmepumpe`), aldri i klartekst på disk. Øktnøkkelen (ContextKey) lagres samme sted.

Valgt løsning: vanlig nøkkelring-element i innloggingsnøkkelringen. Den fungerer for et kommandolinjeverktøy uten provisioneringsprofil. Programmet som lagret elementet har tilgang automatisk. Første gang det andre programmet (appen eller MCP-serveren) leser det, spør macOS om tilgang: velg **Tillat alltid**.

Kun for utvikling: miljøvariablene `MELCLOUD_EMAIL` og `MELCLOUD_PASSWORD` brukes i stedet for nøkkelringen når begge er satt. Ikke bruk dette i daglig drift.

## Data

Historikken ligger i `~/Library/Application Support/Varmepumpe/varmepumpe.sqlite` (WAL-modus), delt mellom appen og MCP-serveren. `VARMEPUMPE_DB_PATH` overstyrer stien.

## Sikkerhet og begrensninger

- **Lese fritt, skrive bare med godkjenning.** Alle verktøy som endrer varmepumpen ber Claude om å få brukerens ja først. Støtter klienten MCP-bekreftelse (elicitation), spør serveren i tillegg selv. Avviste endringer sendes ikke, men logges.
- Alle endringer logges med kilde (app eller claude), gammel og ny verdi, begrunnelse og resultat.
- Maks 12 sendinger per time og minst 5 sekunder mellom to sendinger, til sammen for appen og Claude. Flere endringer fra Kontroll-skjermen sendes samlet som én sending.
- Godtar ikke MELCloud e-post eller passord, stopper all henting til ny innlogging er lagret, så kontoen ikke blir sperret.
- Status hentes fra MELCloud høyst én gang i minuttet, og ellers fra lageret når dataene er yngre enn 10 minutter. Historikk hentes høyst én gang i timen per rapporttype.
- Svarer MELCloud med «for mye trafikk» (HTTP 429), stopper alle nettverkskall i begge programmer til blokkeringen er over (Retry-After, ellers 2 timer).
- Ønsket temperatur rundes til 0,5 °C og avvises utenfor enhetens grenser for valgt modus.
- Feilkodeforklaringer er usikre: det finnes ingen offentlig feilkodetabell for MSZ-RW i MELCloud.

## Variabler

| Variabel | Betydning |
|---|---|
| `VARMEPUMPE_BACKEND=mock` | Bruk simulert varmepumpe |
| `VARMEPUMPE_DB_PATH` | Sti til SQLite-databasen |
| `MELCLOUD_EMAIL`, `MELCLOUD_PASSWORD` | Kun utvikling: innlogging uten nøkkelring |
| `VARMEPUMPE_SCREEN` | Kun utvikling: skjermen appen åpner på (overview, control, history, health, activity) |
