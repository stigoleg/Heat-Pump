# Varmepumpe

Styring og helseovervåking av en Mitsubishi Electric MSZ-RW25VG (luft-til-luft) via klassisk MELCloud, for macOS. Prosjektet har to deler:

- **HeatPumpKit** (`Packages/HeatPumpKit`): felles Swift-bibliotek med MELCloud-klient, lokal historikk i SQLite, helsemotor og kunnskapsdokumenter.
- **varmepumpe-mcp**: en MCP-server (stdio) som lar Claude lese status og historikk og foreslå endringer.

SwiftUI-appen kommer i neste runde og bygger på det samme biblioteket.

## Bygg og test

Krever Xcode 27 / Swift 6.4 og macOS 26.

```sh
cd Packages/HeatPumpKit
swift build
swift test
```

MCP-serveren havner i `Packages/HeatPumpKit/.build/debug/varmepumpe-mcp`. Den trenger ressursmappen `HeatPumpKit_HeatPumpKit.bundle` som ligger ved siden av.

## Kjør med simulert varmepumpe

```sh
VARMEPUMPE_BACKEND=mock VARMEPUMPE_DB_PATH=/tmp/varmepumpe-test.sqlite \
  Packages/HeatPumpKit/.build/debug/varmepumpe-mcp
```

Den simulerte varmepumpen gir realistiske vinterdata og en feil i feilloggen omtrent hver 17. dag.

## Koble til Claude Code

```sh
claude mcp add varmepumpe -- /full/sti/til/Packages/HeatPumpKit/.build/debug/varmepumpe-mcp
```

Prompten `helsesjekk` gir en full helsesjekk med prioritert oppsummering. Kunnskapsdokumentene er tilgjengelige som ressurser under `varmepumpe://knowledge/…`.

## Innlogging

E-post og passord til MELCloud lagres i macOS-nøkkelringen (tjeneste `com.stigole.varmepumpe`), aldri i klartekst på disk. Øktnøkkelen (ContextKey) lagres samme sted.

Valgt løsning: vanlig nøkkelring-element i innloggingsnøkkelringen. Den fungerer for et kommandolinjeverktøy uten provisioneringsprofil. Programmet som lagret elementet har tilgang automatisk. Første gang det andre programmet (appen eller MCP-serveren) leser det, spør macOS om tilgang: velg **Tillat alltid**.

Kun for utvikling: miljøvariablene `MELCLOUD_EMAIL` og `MELCLOUD_PASSWORD` brukes i stedet for nøkkelringen når begge er satt. Ikke bruk dette i daglig drift.

## Data

Historikken ligger i `~/Library/Application Support/Varmepumpe/varmepumpe.sqlite` (WAL-modus), delt mellom appen og MCP-serveren. `VARMEPUMPE_DB_PATH` overstyrer stien.

## Sikkerhet og begrensninger

- **Lese fritt, skrive bare med godkjenning.** Alle verktøy som endrer varmepumpen ber Claude om å få brukerens ja først. Støtter klienten MCP-bekreftelse (elicitation), spør serveren i tillegg selv. Avviste endringer sendes ikke, men logges.
- Alle endringer logges med kilde (app eller claude), gammel og ny verdi, begrunnelse og resultat.
- Maks 12 endringer per time, til sammen for appen og Claude.
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
