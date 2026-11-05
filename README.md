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

Kopier `Varmepumpe.app` til Programmer-mappen. Første gang uten innlogging viser appen en velkomstside der du logger inn på MELCloud. Appen henter bare data mens vinduet er åpent, og avsluttes når du lukker det.

## Kjør med simulert varmepumpe (demo)

```sh
open -n --env VARMEPUMPE_BACKEND=mock --env VARMEPUMPE_DB_PATH=/tmp/varmepumpe-demo.sqlite \
  build/DerivedData/Build/Products/Debug/Varmepumpe.app

VARMEPUMPE_BACKEND=mock VARMEPUMPE_DB_PATH=/tmp/varmepumpe-demo.sqlite \
  build/DerivedData/Build/Products/Debug/Varmepumpe.app/Contents/Helpers/varmepumpe-mcp
```

Appen viser merket «Demo-data». MCP-serveren i demo-modus viser godkjenningsvinduet som ellers, med mindre `VARMEPUMPE_APPROVAL` er satt. Den simulerte varmepumpen gir realistiske vinterdata og en feil i feilloggen omtrent hver 17. dag. I demo-modus er lokal tilkobling slått på mot en simulert Wi-Fi-modul (192.168.1.50) som svarer gjennom samme kryptering og tolkning som den ekte, med kompressorrunder på 300–1200 W og en uke med målinger fra start.

## Koble til Claude Code

Innstillinger → Claude i appen viser den nøyaktige kommandoen med riktig sti, med en kopier-knapp. For en app i Programmer-mappen:

```sh
claude mcp add varmepumpe --scope user -- "/Applications/Varmepumpe.app/Contents/Helpers/varmepumpe-mcp"
```

Hver endring må godkjennes i vinduet på Macen. Ikke legg likevel `set_*`-verktøyene til i Claudes liste over verktøy som er tillatt uten å spørre.

Prompten `helsesjekk` gir en full helsesjekk med prioritert oppsummering. Kunnskapsdokumentene er tilgjengelige som ressurser under `varmepumpe://knowledge/…`.

## Innlogging

E-post og passord legges inn i appen (Innstillinger → Konto, eller velkomstsiden). De lagres i macOS-nøkkelringen (tjeneste `com.stigole.varmepumpe`), aldri i klartekst på disk. Øktnøkkelen (ContextKey) lagres samme sted.

Valgt løsning: vanlig nøkkelring-element i innloggingsnøkkelringen. Den fungerer for et kommandolinjeverktøy uten provisioneringsprofil. Programmet som lagret elementet har tilgang automatisk. Første gang det andre programmet (appen eller MCP-serveren) leser det, spør macOS om tilgang: velg **Tillat alltid**.

Kun for utvikling: miljøvariablene `MELCLOUD_EMAIL` og `MELCLOUD_PASSWORD` brukes i stedet for nøkkelringen når begge er satt. Ikke bruk dette i daglig drift.

## Strømpris og kostnad

Velg strømavtale under **Innstillinger → Strømpris**:

- **Norgespris**: fast pris per kWh (standard 50 øre inkl. mva, kan endres). Ingen strømstøtte.
- **Spotpris via Tibber**: lag en personlig nøkkel på <https://developer.tibber.com/settings/access-token>, lim den inn og trykk **Lagre og test**. Nøkkelen lagres i nøkkelringen (tjeneste `com.stigole.varmepumpe`, konto `tibber-token`) og brukes bare når timepriser hentes.
- **Spotpris uten Tibber**: timepriser fra hvakosterstrommen.no for valgt prisområde (NO1–NO5), med påslaget fra strømselskapet. Mva legges til (ikke i NO4).

Nettleiens energiledd er forhåndsutfylt med Elvias satser for husholdninger fra 1. juli 2026 (dag 46,40 øre, natt/helg/helligdag 31,40 øre, inkl. avgifter og mva) og kan endres. Kapasitetsleddet er ikke med, fordi det avhenger av hele husets høyeste forbruk. For spotavtaler trekkes strømstøtte fra: staten dekker 90 % av timeprisen over 77 øre/kWh eks. mva (96,25 øre inkl. mva) i 2026.

Kostnad per døgn = forbruk × (strøm + nettleie − støtte). Har appen forbruk per time (fra strømmåleren i pumpen, målt mens appen er åpen), brukes timeprisen for hver time. Ellers prises døgnets kWh med døgnets snittpris, og beløpet merkes «anslag». Priser hentes høyst én gang i timen, morgendagens priser først etter kl. 13.30.

## Lokal tilkobling (effekt og kompressor)

Wi-Fi-modulen i varmepumpen svarer også direkte på hjemmenettet. Under **Innstillinger → Lokal tilkobling** kan appen lese den der, i tillegg til MELCloud. Det gir effekt i watt, om kompressoren går (og hvor fort, i Hz), antall kompressorstarter per time, raskere temperaturer, feilkoden fra innedelen og en nøyaktig strømmåler (0,1 kWh), slik at kostnaden per time blir eksakt i stedet for et anslag.

Slik slår du det på:

1. Åpne Innstillinger → Lokal tilkobling.
2. Trykk **Finn automatisk**. Appen prøver først lagret adresse, og leter ellers på Macens eget nett (/24) etter varmepumpens maskinvareadresse fra MELCloud. Adressen vises ikke. Du kan også skrive inn IP-adressen fra ruterens enhetsliste.
3. Trykk **Test** (viser fastvareversjon, Wi-Fi-signal, effekt og temperaturer), slå på bryteren og trykk **Lagre**.

Gi gjerne varmepumpen fast IP-adresse i ruteren. Bytter den adresse og slutter å svare, prøver appen å finne den igjen automatisk, høyst én gang i timen.

Sikkerhet og begrensninger:

- **Bare lesing, håndhevet i koden.** Den lokale klienten har én operasjon: en statusforespørsel (`<CSV></CSV>` til `/smart`). Den sender aldri `CONNECT`-innstillingen (som kan koble modulen fra MELCloud), kommandoer, omstart, ECHONET eller admin-sider. En test sjekker at klartekstet er nøyaktig `<CSV></CSV>`. All styring går fortsatt via MELCloud.
- Appen godtar bare private IPv4-adresser (10.x, 172.16–31.x, 192.168.x), følger aldri omdirigeringer og godtar bare svar fra adressen den spurte.
- Automatisk avlesning og automatisk søk skjer bare når Macen er på samme /24-nett som den lagrede adressen. Borte fra hjemmet settes lokal avlesning på pause («Ikke på hjemmenettet»), uten forespørsler eller søk på det andre nettet.
- «Test» av en annen adresse enn den lagrede lagrer ingen måling og endrer ikke feiltelleren.
- Høyst én forespørsel per 20 sekunder (felles for appen og Claude), 5 sekunders tidsavbrudd, og etter feil venter appen 2, 4, 8 og deretter 10 minutter. Appen leser hvert minutt mens den er åpen; Claude (`get_live_status`) gjenbruker en avlesning under ett minutt gammel.
- MAC-adresse, serienummer og profilkoder fjernes rett etter dekryptering og lagres eller vises aldri. MCP-serveren viser heller ikke MAC-adresse eller serienummer fra MELCloud.
- Endepunktet er uoffisielt. Det kan slutte å virke etter en fastvareoppdatering av modulen (for eksempel 43.00 eller nyere). Da virker resten av appen som før.
- Av som standard. macOS spør første gang om appen får bruke lokalt nettverk; svar Tillat.

Målingene lagres i tabellen `local_samples` (omtrent én per minutt mens appen er åpen). Etter 90 dager tynnes de ut til én per 10. minutt, og etter ett år til én per time. Helsesjekken bruker dem til regler for korte sykluser (mange kompressorstarter per time), uvanlig høyt forbruk for temperaturen, feilkode fra modulen og modul som ikke svarer lokalt. Grensene er tommelfingerregler og er beskrevet i kunnskapsdokumentet om vedlikehold.

## Lys og mørk modus

Velg **System**, **Lys** eller **Mørk** med knappen i verktøylinjen (halvfylt sirkel, sol eller måne), under **Visning → Utseende** (⌘⇧L bytter mellom de tre), eller under **Innstillinger → Generelt**. Valget lagres og gjelder hele appen, også Innstillinger og dialoger.

## Endringer sendes automatisk

Endringer i Kontroll og på termostaten på Oversikt sendes automatisk omtrent 2 sekunder etter siste justering (for glidebryter og termostathjul: etter at du slipper). Flere justeringer samles i én sending. Stiller du tilbake til nåværende verdi, sendes ingenting. Merket øverst viser «Endret…», «Sender…», «Sendt – venter på pumpen», «Bekreftet» eller «Feil: …». Er grensen på 12 sendinger per time nådd, venter endringen og sendes når det er lov igjen. Når færre enn 4 sendinger gjenstår denne timen, vises antallet.

## Data

Historikken ligger i `~/Library/Application Support/Varmepumpe/varmepumpe.sqlite` (WAL-modus), delt mellom appen og MCP-serveren. `VARMEPUMPE_DB_PATH` overstyrer stien.

## Sikkerhet og begrensninger

- **Lese fritt, skrive bare med godkjenning.** Når Claude kaller et `set_*`-verktøy, viser MCP-serveren selv et vindu på Macen: «Claude vil endre varmepumpen», med endringen og Claudes begrunnelse. Endringen sendes bare hvis du trykker **Godkjenn**. **Avvis** (standardknappen, også Return og Esc), ingen svar innen 120 sekunder, eller at vinduet ikke kan vises (ingen grafisk økt), gjør at endringen ikke sendes. Dette gjelder uansett klient og tillatelsesmodus i Claude Code. Avviste endringer logges.
- Alle endringer logges med kilde (app eller claude), gammel og ny verdi, begrunnelse og resultat.
- Maks 12 sendinger per time og minst 5 sekunder mellom to sendinger, til sammen for appen og Claude. Endringer fra appen sendes automatisk og samlet som én sending.
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
| `VARMEPUMPE_APPROVAL=auto-approve` / `auto-reject` | Kun utvikling og tester: svarer automatisk i stedet for godkjenningsvinduet. Virker bare sammen med `VARMEPUMPE_BACKEND=mock`; med ekte MELCloud ignoreres den. |
| `VARMEPUMPE_SCREEN` | Kun utvikling: skjermen appen åpner på (overview, control, history, health, activity) |
| `VARMEPUMPE_HISTORY_TAB` | Kun utvikling: fanen Historikk åpner på (temperature, energy, energy-kr, operation, power) |
| `VARMEPUMPE_APPEARANCE` | Kun utvikling: `light`, `dark` eller `system`; overstyrer valget i appen uten å lagre det (skjermbilder) |
| `VARMEPUMPE_SETTINGS_TAB` | Kun utvikling: åpner Innstillinger på fanen (generelt, konto, strompris, lokal, claude, data) |
| `VARMEPUMPE_MOCK_CYCLING=short` | Kun utvikling, sammen med `VARMEPUMPE_BACKEND=mock`: den simulerte kompressoren går i korte runder, så regelen for korte sykluser kan vises |

## Appikon

Kilden er `App/Icon/AppIcon.svg`. Kjør `App/Icon/render.sh` (krever `rsvg-convert`, `brew install librsvg`) for å lage alle størrelser i `App/Assets.xcassets/AppIcon.appiconset`.
