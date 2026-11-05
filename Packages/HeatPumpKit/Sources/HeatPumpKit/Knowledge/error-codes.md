# Feilkoder

## Viktig forbehold

Mitsubishi har ingen offentlig feilkodetabell for MSZ-RW-serien slik den vises i MELCloud. Servicehåndboken for MSZ-RW (OBH902C) har vi ikke. Tabellene under er hentet fra servicehåndboken for den beslektede MSZ-LN-serien (OBH766H) og fra observasjoner i MELCloud. Hvordan MELCloud sin `ErrorCode` henger sammen med blinkekodene er ukjent. Bruk forklaringene som en pekepinn, og la forhandleren stille diagnosen.

## MELCloud

- `ErrorCode` 8000 betyr «ingen feil» på luft-til-luft-enheter (observert i flere åpne integrasjoner).
- `HasError` = sann betyr at enheten melder feil nå.
- Feilloggen i MELCloud gir en tekst (`ErrorMessage`) med start- og sluttid. Den teksten kommer fra Mitsubishi og er den beste kilden vi har.
- Noen 4-sifrede koder er kjent fra andre Mitsubishi-serier (for eksempel 5101 romføler, 5102 rørføler, 6840 kommunikasjon inne/ute). Det er **ikke** bekreftet at de betyr det samme på MSZ-RW.

## Når driftslampen blinker (MSZ-LN §10-4, beslektet modell)

Driftslampen (POWER) på innedelen blinker et antall ganger, så er den av i 2,5 sekunder, og gjentar mønsteret.

| Blink | Hva det gjelder | Forklaring |
|---|---|---|
| Blinker jevnt (0,5 s på/av) | Feilkobling eller seriesignal | Innedelen mottar ikke signal fra utedelen på 6 minutter. |
| 2 | Temperaturføler i innedel | Rørføler eller romføler er kortsluttet eller brutt. |
| 3 | Viftemotor i innedel | Viftemotoren gir ikke turtallssignal. |
| 4 | Styrekort i innedel | Kortet klarer ikke å lese minnet sitt. |
| 5 | Strømsystem i utedel | Kompressoren har stoppet for overstrøm eller oppstartsfeil tre ganger på rad. |
| 6 | Temperaturfølere i utedel | En føler er kortsluttet eller brutt mens kompressoren går. |
| 7 | Styrekort i utedel | Kortet klarer ikke å lese minnet sitt. |
| 14 eller flere | Annen feil | Blant annet følere, ventiler eller stoppventil. Ikke start igjen før det er reparert. |

Servicehåndboken har i tillegg en «feilminne»-funksjon (§10-2.4) som teknikeren kan bruke. Der betyr 1 blink romføler, 2 blink rørføler, 3 blink seriesignal fra utedel, 11 blink viftemotor og 12 blink styrekort. Tabellen for utedelen (§10-2.5) står i servicehåndboken for utedelen, som vi ikke har.

## Hva du gjør

1. Tell antall blink minst to runder.
2. Noter tidspunkt og eventuell feiltekst fra MELCloud.
3. Slå av varmepumpen. Bruksanvisningen sier at du skal slutte å bruke den og kontakte forhandleren når driftslampen blinker.
