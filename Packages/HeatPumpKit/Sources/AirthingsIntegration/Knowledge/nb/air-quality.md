# Inneluft (Airthings)

Appen leser Airthings-målerne dine gjennom Airthings' API med en API-klient du lager selv. Den bare leser; den endrer aldri noe på målerne.

## Hva verdiene betyr

| Verdi | Hva det er | Bra | Middels | Dårlig |
|---|---|---|---|---|
| Radon | En radioaktiv gass fra grunnen. Lang tids eksponering øker risikoen for lungekreft. | under 100 Bq/m³ | 100–150 | 150 eller mer |
| CO₂ | Karbondioksid fra pusten. Et tegn på hvor godt rommet er luftet. | under 800 ppm | 800–1000 | 1000 eller mer |
| VOC | Flyktige organiske forbindelser fra møbler, maling, rengjøring og matlaging. | under 250 ppb | 250–2000 | 2000 eller mer |
| PM2,5 / PM1 | Svevestøv fra stearinlys, vedovn, matlaging og uteluft. | under 10 µg/m³ | 10–25 | 25 eller mer |
| Luftfuktighet | Relativ luftfuktighet. | 30–60 % | 25–30 eller 60–70 % | under 25 eller 70 % og mer |
| Temperatur | Innetemperatur. | 18–25 °C | utenfor det | – |
| Lufttrykk | Følger været. Endringer kan presse radon ut av grunnen. | – | – | – |

Dette er vanlige standardverdier. Har du satt egne grenser for en måler i Airthings-appen, bruker appen dine (de hentes én gang i døgnet).

## Radon: hva som teller

- Radon vurderes ut fra **årsmiddelverdien**. Direktoratet for strålevern og atomsikkerhet (DSA) anbefaler tiltak når årsmiddelverdien er **100 Bq/m³** eller mer (tiltaksnivået), og sier at den alltid bør være under **200 Bq/m³** (grenseverdien). Grensene er bindende for skoler, barnehager og utleieboliger; for en bolig du eier selv er de en anbefaling.
- Mål i **vinterhalvåret** (midten av oktober til midten av april) i **minst to måneder**, i rommene du bruker mest, i laveste etasje du bor i.
- Korttidsverdien (et snitt av omtrent det siste døgnet) svinger mye med vær, vind, lufttrykk og ventilasjon. Én høy korttidsverdi er ingen dom. Langtidssnittet måleren viser, er den beste pekepinnen på årsmiddelverdien mens du måler.
- Vanlige tiltak: bedre ventilasjon, tetting av sprekker og åpninger mot grunnen, og radonbrønn med vifte. DSAs veileder har mer.

Kilder: DSA, «Anbefalte grenser for radon» (dsa.no/radon/anbefalte-grenser-for-radon) og «Slik måler du radon» (dsa.no/radon/slik-maler-du-radon); strålevernforskriften § 6 (lovdata.no).

## Hvor ofte data kommer

- Med en **Airthings-hub** sender målerne verdier hvert 5. minutt, og radon hver time.
- **Uten hub** kommer verdiene bare til Airthings når Airthings-appen på telefonen synkroniserer med måleren over Bluetooth, så verdiene her kan være timer eller dager gamle. «Målt for … siden» på målerens side viser det.
- Appen spør Airthings om de nyeste verdiene for alle målerne dine høyst hvert 5. minutt, om timehistorikken for hver måler høyst én gang i timen og om grensene én gang i døgnet. Historikken tas vare på i to år.

## Greit å vite

- Airthings gir hver API-klient et begrenset antall forespørsler i timen. Appen holder seg godt under grensen og stopper selv før den nås; sier Airthings likevel nei, venter appen så lenge Airthings ber om.
- Klient-ID og hemmelighet lagres i nøkkelringen på denne Macen. Feil verdier prøves ikke igjen før du lagrer nye.
- På målerens side kan du slå på et varsel for når langtidssnittet for radon er 100 Bq/m³ eller mer (høyst én gang i uken så lenge det varer).
