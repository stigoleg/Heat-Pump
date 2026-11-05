# Enhetsprofil: Mitsubishi Electric MSZ-RW25VG

Dette er fakta om varmepumpen, hentet fra typeskiltet og bruksanvisningen. Serienummer, MAC-adresse, Wi-Fi-navn (SSID) og Wi-Fi-nøkkel er bevisst utelatt.

## Modell

| Felt | Verdi |
|---|---|
| Innedel | MSZ-RW25VG (servicereferanse MSZ-RW25VG-SC1) |
| Type | Luft-til-luft varmepumpe, veggmontert innedel |
| Produsert | april 2022 |
| Kjølemiddel | R32 |
| Spenning | 230 V |
| Kapslingsgrad innedel | IP20 (kun innendørs, tåler ikke vannsprut) |
| Vekt innedel | 14,5 kg |
| Effektforbruk innedel | 21 W (vifte og styring) |
| Merkestrøm innedel | 0,21 A |
| Høyeste tillatte trykk (HP PS) | 4,17 MPa |
| Wi-Fi-modul | Innebygd (MB507IF ifølge bruksanvisningen), koblet til MELCloud (klassisk) |

## Driftsområde (fra bruksanvisningen)

- Oppvarming: garantert driftsområde er −30 °C til 24 °C ute (tørr temperatur) og 20–27 °C inne. Merkeeffekten er målt ved 20 °C inne og 7 °C ute.
- Kjøling: −10 °C til 46 °C ute.
- Ved svært lave utetemperaturer faller varmeeffekten. Det er normalt.

## MELCloud

- Enheten bruker klassisk MELCloud (app.melcloud.com), ikke MELCloud Home.
- MELCloud rapporterer romtemperatur, ønsket temperatur, modus, vifte, spjeld, Wi-Fi-signal (dBm) og feilstatus.
- MELCloud har ikke noe eget varsel for filterrengjøring. Det må registreres manuelt i appen.

## Sikkerhetsmerknad om Wi-Fi-modulen

Wi-Fi-adaptere i samme gruppe som MSZ-RW25VG-SC1 er omfattet av sårbarheten CVE-2026-5667 (fast kodet passord for adapterens eget tilgangspunkt) for adapterversjon 42.00 og eldre. Feilen er rettet i versjon 43.00. Sårbarheten er bare relevant når enheten ikke er koblet til en ruter (oppsettmodus). Sjekk fastvareversjonen i MELCloud eller hos forhandleren, og hold enheten koblet til ruteren. Appen viser modulens fastvareversjon under Innstillinger → Konto (MELCloud oppgir for eksempel 34000, som betyr versjon 34.00). Oppdatering anbefales, men er ikke akutt så lenge enheten er koblet til hjemmenettet. Oppdateringen startes i den offisielle MELCloud-appen; Varmepumpe-appen og Claude starter ikke fastvareoppdateringer.
