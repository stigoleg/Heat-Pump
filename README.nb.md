<p align="center">
  <img src="docs/icon.png" width="128" alt="Husly-ikonet">
</p>

<h1 align="center">Husly</h1>

<p align="center">
  En Mac-app for klima og energi i hjemmet: styr og overvåk en Mitsubishi Electric-varmepumpe via MELCloud, følg strømforbruket med Tibber og inneluften med Airthings, med Claude som rådgiver.
</p>

<p align="center">
  <a href="https://github.com/stigoleg/Heat-Pump/actions/workflows/ci.yml"><img src="https://github.com/stigoleg/Heat-Pump/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/stigoleg/Heat-Pump/releases/latest"><img src="https://img.shields.io/github/v/release/stigoleg/Heat-Pump" alt="Siste versjon"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-blue" alt="macOS 26+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/lisens-GPL--3.0-green" alt="GPL-3.0"></a>
</p>

<p align="center">
  🇬🇧 <a href="README.md">English</a> · 🇳🇴 Norsk
</p>

<p align="center">
  <img src="docs/screenshots/nb/oversikt-lys.png" width="49%" alt="Oversikt i lys modus">
  <img src="docs/screenshots/nb/oversikt-mork.png" width="49%" alt="Oversikt i mørk modus">
</p>

Husly (tidligere Varmepumpe) startet som en bedre MELCloud-app og dekker nå klima og energi i hjemmet. Den samler status, styring, historikk, strømkostnad, helse, strømmålere og inneluft i ett ryddig vindu, skrevet for folk som ikke kan noe om varmepumper. Claude kan lese alt appen ser og foreslå tiltak, men hver endring på pumpen må godkjennes av deg.

Laget og testet for en **MSZ-RW25VG** med innebygd Wi-Fi. Andre luft-til-luft-modeller i klassisk MELCloud bør også virke, men er ikke testet. Appen finnes på norsk og engelsk.

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
- **Kontroll** – av/på, modus, temperatur (glidebryter og stepper), viftehastighet og luftretning. Endringer sendes automatisk et par sekunder etter at du har stilt inn.
- **Ukeplan** – lag og endre ukeplanen i MELCloud: hendelser per ukedag med tid, av/på, modus, temperatur, vifte og luftretning, kopiering av en dag og ferdige maler (nattsenking, borte på dagtid). Planen kjører i MELCloud, også når Macen er av.
- **Historikk** – temperatur, energi og kostnad, drift og effekt, for 24 timer, 7 dager, 30 dager eller ett år.
- **Prognose** – været de neste 48 timene og ni dager fram, strømpris en uke fram (publiserte priser og et tydelig merket anslag for dagene etter), forventet forbruk og kostnad per dag, og prisstyring.
- **Menylinjen** – valgfritt (Innstillinger → Generelt → Menylinjen): modus, temperaturer, effekt, kostnad eller pris i menylinjen, slik du velger, og et panel med status, dagens tall, helse og kontrollene. Appen fortsetter da når vinduet lukkes.
- **Prisstyring** – senker ønsket temperatur i dyre timer og setter den tilbake etterpå. Virker bare mens appen kjører og Macen er på og våken; med prisstyring på fortsetter appen i menylinjen når vinduet lukkes.
- **Strømkostnad** – Norgespris, spotpris via Tibber eller spotpris fra hvakosterstrommen.no, med nettleie og strømstøtte. Prisene farges fra svært billig til svært dyr.
- **Helse** – feillogg med forklaringer, påminnelser om filterrengjøring og varsler om korte sykluser, uvanlig høyt forbruk, hyppig avriming, svakt Wi-Fi og fastvare. Fastvareoppdateringer av Wi-Fi-modulen kan startes og følges her.
- **Borte hjemmefra** – frostsikring og feriemodus.
- **Lokal tilkobling** – leser effekt, kompressor, avriming og en nøyaktig strømmåler direkte fra Wi-Fi-modulen på hjemmenettet. Bare lesing.
- **Husets strømforbruk** – fra Tibber, med varmepumpens andel.
- **Strømmåler (Tibber)** – valgfritt: velg Legg til enhet … (sidepanelet, Arkiv-menyen eller Innstillinger → Enheter) → Tibber, så vises Tibber-hjemmet ditt som en enhet med effekt nå (med Tibber Pulse eller Watty), dagens forbruk og kostnad, og historikk per time og døgn. Den bruker samme nøkkel som Tibber-prisene.
- **Inneluft (Airthings)** – valgfritt: velg Legg til enhet … → Airthings og skriv inn klient-ID og hemmelighet fra en API-klient du lager på Airthings' utviklerside. Hver måler vises som en enhet med radon (kort- og langtidssnitt), CO₂, VOC, svevestøv, luftfuktighet, temperatur og lufttrykk, nivåer (bra/middels/dårlig, etter dine egne grenser i Airthings-appen), råd, historikk i opptil to år, et kort på Hjem og et valgfritt varsel når langtidssnittet for radon når 100 Bq/m³. Bare lesing. Claude kan også lese det (`get_air_quality`, `get_air_quality_history`).
- **Claude** – innebygd MCP-server med 25 verktøy, en helsesjekk og kunnskapsdokumenter om vedlikehold og feilkoder.
- **Lys og mørk modus** – med ett klikk i verktøylinjen eller ⌘⇧L.
- **Norsk og engelsk** – følger språket i macOS, eller velges under Innstillinger → Generelt → Språk.

## Skjermbilder

| Hjem med flere enheter | Inneluft (Airthings) |
|---|---|
| <img src="docs/screenshots/nb/hjem-enheter.png" alt="Hjem-oversikt med varmepumpe, strømmåler og luftkvalitetsmåler"> | <img src="docs/screenshots/nb/inneluft.png" alt="Oversikt for luftkvalitetsmåler"> |

**Menylinjen.** Oppføringen viser det du velger (her modus, innetemperatur og effekt): <img src="docs/screenshots/nb/menylinje-tittel.png" height="22" alt="Oppføringen i menylinjen">

| Menylinjepanel, lyst | Menylinjepanel, mørkt |
|---|---|
| <img src="docs/screenshots/nb/menylinje-panel-lys.png" width="360" alt="Menylinjepanel i lys modus"> | <img src="docs/screenshots/nb/menylinje-panel-mork.png" width="360" alt="Menylinjepanel i mørk modus"> |

**Legg til enhet** (sidepanelet, Arkiv-menyen eller Innstillinger → Enheter):

<img src="docs/screenshots/nb/legg-til-enhet.png" width="70%" alt="Legg til enhet: MELCloud, Tibber og Airthings">

| Kontroll | Helse |
|---|---|
| <img src="docs/screenshots/nb/kontroll.png" alt="Kontroll"> | <img src="docs/screenshots/nb/helse.png" alt="Helse"> |

| Historikk: temperatur | Historikk: energi og kostnad |
|---|---|
| <img src="docs/screenshots/nb/historikk-temperatur.png" alt="Temperaturhistorikk"> | <img src="docs/screenshots/nb/historikk-energi.png" alt="Energi og kostnad"> |

| Historikk: effekt | Historikk: drift |
|---|---|
| <img src="docs/screenshots/nb/historikk-effekt.png" alt="Effekt"> | <img src="docs/screenshots/nb/historikk-drift.png" alt="Drift"> |

| Borte hjemmefra | Innstillinger: strømpris |
|---|---|
| <img src="docs/screenshots/nb/borte.png" alt="Borte hjemmefra"> | <img src="docs/screenshots/nb/innstillinger-strompris.png" alt="Strømpris"> |

Skjermbildene er tatt i demo-modus med simulerte data.

## Installer

1. Last ned `Husly-<versjon>.dmg` fra [siste versjon](https://github.com/stigoleg/Heat-Pump/releases/latest).
2. Åpne den og dra Husly til Programmer.

Har du allerede Varmepumpe 1.1.5 eller nyere? Den oppdaterer seg selv til Husly der den ligger (`Varmepumpe.app`) og beholder innlogging, historikk og Claude-oppsett, så du trenger ikke diskbildet.
3. Åpne appen. Den er signert med Developer ID og notarisert av Apple, så den åpnes uten advarsel.

Krever macOS 26 eller nyere, på Apple Silicon eller Intel.

Fra versjon 1.1.5 oppdaterer appen seg selv. Den ser etter nye versjoner på GitHub én gang i døgnet, laster dem ned og installerer dem når du avslutter appen. Du kan også velge «Installer og start på nytt». En nedlasting tas bare i bruk når sjekksummen stemmer og appen er signert og notarisert av samme utvikler. Valget og knappen «Se etter nå» ligger under Innstillinger → Generelt, og menyen Husly har «Se etter oppdateringer …».

## Kom i gang

1. **Logg inn** med samme e-post og passord som i MELCloud-appen. Innloggingen lagres i nøkkelringen på Macen.
2. **Velg strømavtale** under Innstillinger → Strømpris: Norgespris, spotpris via Tibber (krever en [personlig nøkkel](https://developer.tibber.com/settings/access-token)) eller spotpris uten Tibber. Nettleien er forhåndsutfylt med Elvias satser og kan endres.
3. **Slå på lokal tilkobling** (valgfritt) under Innstillinger → Lokal tilkobling → **Finn automatisk** → **Test**. macOS spør om tilgang til lokalt nettverk; svar Tillat.
4. **Sted for værvarsel** hentes fra MELCloud. Vil du ha et annet sted, søker du etter adresse eller sted under Innstillinger → Vær, eller klikker i kartet.

**Språk.** Appen bruker språket i macOS: norsk på en norsk Mac, ellers engelsk. Under Innstillinger → Generelt → Språk kan du velge norsk eller engelsk uansett; endringen gjelder etter omstart av appen. Claude-hjelperen følger samme valg, så godkjenningsvinduet og helsetekstene kommer på samme språk. Tekst som allerede er lagret, som begrunnelser i endringsloggen, står på språket den ble skrevet på.

Appen henter data bare mens vinduet er åpent, og avsluttes når du lukker det. Unntakene er menylinjen (Innstillinger → Generelt → Menylinjen) og prisstyring: når en av dem er på, fortsetter appen i menylinjen, og med menylinjen på uten ikon i Dock mens vinduet er lukket. Hentingen tar pause mens Macen sover. Claude kan likevel lese når appen er lukket.

## Koble til Claude

Innstillinger → Claude viser kommandoen med riktig sti og en kopier-knapp:

```sh
claude mcp add varmepumpe --scope user -- "/Applications/Husly.app/Contents/Helpers/varmepumpe-mcp"
```

Har du oppdatert fra Varmepumpe, ligger appen fortsatt i `/Applications/Varmepumpe.app`, og kommandoen du allerede har lagt til virker videre.

Start Claude Code på nytt og spør for eksempel «Kjør helsesjekk på varmepumpa». Første gang spør macOS om MCP-serveren får lese innloggingen i nøkkelringen; velg **Tillat alltid**.

Når Claude vil endre noe, viser Macen et eget vindu, «Claude vil endre varmepumpen», med endringen og Claudes begrunnelse. Endringen sendes bare hvis du trykker **Godkjenn**. Avvis, Esc eller ingen svar innen to minutter stopper den. Dette gjelder uansett tillatelsesmodus i Claude Code. Legg likevel ikke `set_*`-verktøyene eller `start_firmware_update` i listen over verktøy som er tillatt uten å spørre.

<details>
<summary>Verktøy og ressurser for Claude</summary>

- **Lesing:** `get_status`, `get_live_status`, `get_health_report`, `get_error_log`, `get_history`, `get_energy`, `get_prices`, `get_forecast`, `get_house_consumption`, `get_maintenance_status`, `get_away_settings`, `get_weekly_timer`, `get_firmware_status`, `get_change_log`, `get_device_info`, `refresh`
- **Endring (med godkjenning):** `set_power`, `set_mode`, `set_temperature`, `set_fan_speed`, `set_vanes`, `set_frost_protection`, `set_holiday_mode`, `start_firmware_update`, `record_maintenance`
- **Prompt:** `helsesjekk` – full gjennomgang med prioritert oppsummering
- **Ressurser:** `varmepumpe://knowledge/…` – varmepumpeprofil, vedlikehold, feilkoder, når du bør ringe forhandleren og råd om trygg drift

</details>

## Slik virker det

```
Husly.app (SwiftUI)               varmepumpe-mcp (stdio, i Contents/Helpers)
        \                                  /
         HeatPumpKit (Swift-pakke)
           HeatPumpService – hurtigbuffer, grenser for trafikk, revisjonslogg
           MELCloud-klient (styring) · lokal klient (bare lesing) · Tibber · Airthings · MET
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

Timevarsel fra [MET Norway](https://api.met.no/) (samme kilde som yr.no), lisens CC BY 4.0. Posisjonen rundes av til omtrent 1 km før den sendes til MET. Stedssøket og kartet i innstillingene bruker Apple Kart, så det du søker etter, sendes til Apple. Appen henter høyst én gang i timen og respekterer METs hurtigbufferregler. Du kan oppgi en kontakt-e-post for MET under Innstillinger → Vær; den fylles aldri inn automatisk.

Anslaget for morgendagens forbruk og kostnad bygger på sammenhengen mellom forbruk og graddager de siste 45 dagene, og vises først når det finnes minst 10 dager med data. Prognose viser det samme anslaget for hver dag i varselet, inntil sju dager fram.

**Prisanslag.** For timene etter de publiserte prisene (morgendagens kommer rundt kl. 13) viser Prognose et anslag: døgnprofilen per time de siste 28 dagene (hverdager og helg/helligdag hver for seg), skalert til snittet den siste uka. Har dagsprisen fulgt utetemperaturen de siste 30 dagene (|r| ≥ 0,4, minst 14 dager), flyttes nivået etter værvarselet. Området rundt anslaget er 25–75-persentilen av feilene metoden ville gjort de siste ukene. Krever minst 14 dager med lagrede priser; med Norgespris trengs det ikke.

</details>

<details>
<summary><b>Prisstyring</b></summary>

Slås på under Prognose. I timer Tibber (eller appen, mot snittet siste 72 timer) merker som dyre, senkes ønsket temperatur 1 °C, i svært dyre 2 °C, aldri under en laveste temperatur (standard 18 °C), og høyst åtte timer per døgn (de dyreste; kan endres). Valgfritt: +1 °C i opptil to av de billigste timene de fire timene før en dyr periode. Grunnlaget er temperaturen i ukeplanen når den er på, ellers den temperaturen du sist stilte inn selv.

- Bruker bare publiserte priser, aldri anslaget, og bare i varmemodus. Av/på og modus endres aldri.
- Høyst én endring i timen og fire i løpet av en time, og bare ved skifte i planen. Går en endring ikke gjennom, prøver den én gang til senere i samme periode. Den står over når feriemodus er på, når pumpen er av, ved sperre fra MELCloud og ti minutter rundt hendelser i ukeplanen.
- Endrer du temperaturen selv (i appen, med fjernkontrollen eller i MELCloud), tar den pause til neste skifte, og din temperatur blir den nye grunntemperaturen. Endringer fra ukeplanen regnes ikke som dine.
- Når den slås av, før Macen sover og når appen avsluttes, settes temperaturen tilbake først. Skjer ikke det (strømbrudd, krasj), blir temperaturen stående, men aldri lavere enn laveste temperatur. Neste gang appen starter, retter den seg etter planen.
- Med prisstyring på lukkes ikke appen når vinduet lukkes. Den ligger i menylinjen med pris nå, temperatur, status og neste steg, og der kan du åpne vinduet, slå av prisstyringen eller avslutte. Med menylinjen på (Innstillinger → Generelt → Menylinjen) står prisstyringens status i panelet der i stedet.
- Endringene logges med kilde «Prisstyring» og teller i de 12 endringene per time. Claude kan lese status og plan (`get_prices`), men ikke endre dem.

</details>

<details>
<summary><b>Endringer sendes automatisk</b></summary>

Endringer i Kontroll og på termostaten sendes omtrent 2 sekunder etter siste justering. Flere justeringer samles i én sending, og stiller du tilbake til nåværende verdi, sendes ingenting. Merket øverst viser «Endret…», «Sender…», «Sendt – venter på pumpen», «Bekreftet» eller feilen. Hver sending inneholder hele innstillingsobjektet fra MELCloud, slik at felt du ikke endret, beholder verdien.

</details>

## Sikkerhet og personvern

- **Claude leser fritt, men endrer bare med godkjenning** i vinduet på Macen. Alle endringer logges med kilde (app, Claude eller prisstyring), gammel og ny verdi, begrunnelse og resultat, og vises under Claude-aktivitet.
- **Høflig mot MELCloud.** Status hentes høyst hvert minutt og gjenbrukes i 10 minutter. Høyst 12 endringer per time med minst 5 sekunder mellom. Ved «for mye trafikk» (HTTP 429) stopper all trafikk til sperren er over, og ved avvist passord stopper all henting til ny innlogging er lagret.
- **Hemmeligheter** (MELCloud-innlogging, økt, Tibber-nøkkel og Airthings' klient-ID og hemmelighet) ligger i macOS-nøkkelringen, aldri i klartekst på disk.
- **Andre tjenester:** MET Norway (vær), Tibber (priser og forbruk, bare med nøkkel; effekt nå over én tilkobling mens appen kjører, bare med strømmåleren slått på), Airthings (bare når den er lagt til: en tilgangsnøkkel fra accounts-api.airthings.com med klient-ID og hemmelighet, deretter de nyeste verdiene for alle målere høyst hvert 5. minutt, hver målers timehistorikk høyst hver time og grensene én gang i døgnet, fra consumer-api.airthings.com), hvakosterstrommen.no (priser), Apple Kart (stedssøk i innstillingene) og GitHub (nye versjoner, én gang i døgnet). Ingen analyse eller sporing.
- **Ingen offisiell feilkodetabell** for MSZ-RW er offentlig. Forklaringene av feilkoder er derfor merket med usikkerhet.

Husly er ikke laget av eller tilknyttet Mitsubishi Electric, Tibber eller Airthings. MELCloud er et varemerke for Mitsubishi Electric.

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

**Kunnskapsdokumentene** i `Packages/HeatPumpKit/Sources/HeatPumpKit/Knowledge/<språk>/*.md` (`en` og `nb`) kompileres inn i koden. Kjør `python3 Packages/HeatPumpKit/scripts/generate-knowledge.py` etter endringer; en test feiler hvis det er glemt.

**Språk.** Engelsk er kildespråket i koden, norsk bokmål er oversettelsen. Appens tekster ligger i `App/Resources/Localizable.xcstrings` (hentes ut av kompilatoren), og tekstene fra HeatPumpKit og MCP-serveren i `App/Resources/HeatPumpKit.xcstrings` (skrives med `L10n.tr("…")` og `L10n.format("…", …)`). `make l10n` oppdaterer katalogene og viser tekster som mangler norsk; `TRANSLATIONS=fil.json` fletter inn oversettelser (formatet står i `scripts/l10n.py`). CI og en enhetstest feiler hvis en tekst mangler norsk oversettelse. `make demo LANGUAGE=en` starter demo-modus på engelsk.

**Appikonet** lages fra `App/Icon/AppIcon.svg` med `App/Icon/render.sh` (krever `brew install librsvg`).

**Skjermbilder og agenter.** `scripts/screenshot.sh` tar et skjermbilde i demomodus med fast vindusstørrelse, og `scripts/parity.sh` sammenligner alle skjermer før og etter en endring. [CLAUDE.md](CLAUDE.md) og [docs/architecture.md](docs/architecture.md) beskriver arkitekturen og reglene (på engelsk); skills for [Claude Code](https://claude.com/claude-code) i `.claude/skills/` dekker designsystemet, oversettelse, skjermbilder og release.

<details>
<summary>Miljøvariabler</summary>

| Variabel | Betydning |
|---|---|
| `VARMEPUMPE_BACKEND=mock` | Simulert varmepumpe. Uten `VARMEPUMPE_DB_PATH` bruker den en egen database, `demo.sqlite` ved siden av den ekte, aldri den ekte |
| `VARMEPUMPE_DB_PATH` | Sti til SQLite-databasen |
| `MELCLOUD_EMAIL`, `MELCLOUD_PASSWORD` | Kun utvikling: innlogging uten nøkkelring |
| `VARMEPUMPE_APPROVAL=auto-approve` / `auto-reject` | Kun tester: svarer i stedet for godkjenningsvinduet. Virker bare med `VARMEPUMPE_BACKEND=mock`. |
| `VARMEPUMPE_SCREEN` | Startskjerm: overview, control, schedule, history, outlook, away, health, activity; med to eller flere enheter også `home`, `home/forecast`, `home/activity` og `<enhetsnøkkel>/<skjerm>` (f.eks. `demo:100002/control`) |
| `VARMEPUMPE_HISTORY_TAB` | Startfane i Historikk: temperature, energy, energy-kr, operation, power |
| `VARMEPUMPE_HISTORY_RANGE` | Startperiode i Historikk: day, week, month, year |
| `VARMEPUMPE_SCROLL_TO` | Ruller til en seksjon etter tre sekunder (skjermbilder) |
| `VARMEPUMPE_APPEARANCE` | `light`, `dark` eller `system`, uten å lagre valget |
| `VARMEPUMPE_LANGUAGE` | `en` eller `nb`, uten å lagre valget (også for MCP-serveren) |
| `VARMEPUMPE_SETTINGS_TAB` | Åpner Innstillinger på fanen: generelt, konto, enheter, strompris, lokal, vaer, claude, data |
| `VARMEPUMPE_MOCK_CYCLING=short` | Simulert kompressor går i korte runder |
| `VARMEPUMPE_DEMO_DEVICES` | Simulerte enheter, kommaseparert (standard `heatpump`); `heatpump,heatpump` gir en varmepumpe til («Soverom (simulert)»), `heatpump,meter` et simulert Tibber-hjem («Hjemme (simulert)», nøkkel `demo-meter:home`), `heatpump,airthings` en simulert Airthings Wave Plus («Kjeller (simulert)», nøkkel `demo-airquality:2930000001`) |
| `VARMEPUMPE_SETTINGS_SHEET=add-integration` | Åpner Legg til enhet på Enheter-fanen (skjermbilder; med `VARMEPUMPE_SETTINGS_TAB=enheter`; `add-integration/<id>` åpner på den tjenesten) |
| `VARMEPUMPE_ADD_DEVICE=1` | Åpner Legg til enhet i hovedvinduet (`=<id>`, f.eks. `airthings`, åpner på den tjenesten) |
| `VARMEPUMPE_MENU_BAR` | `on` eller `off` overstyrer Innstillinger → Generelt → Menylinjen uten å lagre; `open` åpner også panelet (skjermbilder) |

</details>

## Lage en ny versjon

Versjoner bygges, signeres med Developer ID, notariseres og publiseres av GitHub Actions ([`release.yml`](.github/workflows/release.yml)) når en tag som `v1.2.3` pushes:

```sh
# Oppdater CHANGELOG.md og versjonen i project.yml (MARKETING_VERSION), commit, så:
git tag v1.2.3
git push origin main v1.2.3
```

Arbeidsflyten kjører testene, bygger en universell app (Apple Silicon og Intel), notariserer og stifter den, og legger `Husly-1.2.3.dmg` (nedlastingen) og `Varmepumpe-1.2.3.zip` (det installerte apper oppdaterer seg fra), hver med SHA-256, under Releases. Teksten hentes fra CHANGELOG.md. Installerte apper finner versjonen via GitHubs «latest release». Den må derfor ikke merkes som forhåndsversjon, og zip-filen må hete `Varmepumpe-<versjon>.zip`.

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
