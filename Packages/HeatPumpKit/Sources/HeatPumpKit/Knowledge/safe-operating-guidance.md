# Trygg og fornuftig bruk

Dette er praktiske og godt etablerte råd. Der noe er usikkert for akkurat denne modellen, står det «usikkert».

## Temperatur og drift

- **Hold jevn temperatur.** En luft-til-luft varmepumpe er mest effektiv når den går jevnt. Hyppig av/på og store hopp i ønsket temperatur gir høyere forbruk og mer slitasje.
- **Senk heller enn å slå av.** Reis du bort noen dager, senk temperaturen et par grader i stedet for å slå av. Dette sparer mest i kaldt vær.
- **Ikke skru høyt for å få varme fortere.** Varmepumpen varmer ikke raskere av at du setter 28 °C. Den går bare lenger og bruker mer strøm.
- **Små justeringer.** En eller to grader om gangen er nok. Vent minst en time og se på resultatet.
- **Velg riktig modus.** Varme om vinteren. «Auto» kan veksle mellom varme og kjøling og er sjelden best i norsk vinter.

## Luftstrøm

- Ikke blokker innedelen med møbler, gardiner eller hyller. Luften må kunne sirkulere fritt.
- Ved oppvarming bør spjeldet peke nedover eller stå på auto, så den varme luften når gulvet.
- Hold dører åpne til rom du vil varme.

## Utedelen om vinteren

- Hold utedelen fri for snø og is, særlig under og foran. Den må få luft og kunne drenere smeltevann.
- Måk rundt utedelen etter snøfall. Ikke hakk is av lamellene med hardt verktøy.
- **Avriming er normalt.** Om vinteren stopper varmepumpen innimellom i opptil 10 minutter for å tine is. Utedelen kan da dampe («hvit røyk») og dryppe. Det er ikke en feil.
- Ved svært lave utetemperaturer synker varmeeffekten. Enheten er garantert å varme ned til −30 °C, men med lavere effekt.

## Hytte og frostsikring

- Mange Mitsubishi-modeller har en egen «10 °C varme»-funksjon for frostsikring. **Usikkert:** Bruksanvisningen for MSZ-RW nevner ikke en slik funksjon, og laveste ønsket temperatur i MELCloud avhenger av enheten. Sjekk minimumsverdien i appen før du stoler på lav vedlikeholdsvarme.
- Ikke bruk varmepumpen som eneste frostsikring hvis strømbrudd eller nettbrudd kan gi skader. Den starter automatisk igjen etter strømbrudd (automatisk omstart), men du får ikke beskjed om den har stoppet.
- **Frostsikring i MELCloud** (appen: «Borte hjemmefra»): når den er på, holder varmepumpen rommet mellom en laveste og høyeste temperatur selv om den ellers står av. Laveste kan være 4–14 °C, høyeste 6–16 °C, og høyeste må være minst 2 °C over laveste. 8–12 °C er et vanlig valg for et hus eller en hytte som står tom.
- **Feriemodus**: velg start og slutt. I perioden kan varmepumpen stå av, og da er det frostsikringen som hindrer at huset blir for kaldt. Appen og Claude slår derfor ikke på feriemodus før frostsikring er på, og slår ikke av frostsikring mens feriemodus er på. Laveste temperatur på 8 °C eller mer anbefales.
- **Tidene i feriemodus**: hvordan MELCloud lagrer tidspunktene (UTC eller lokal tid) er ikke bekreftet. Etter en endring viser appen tidene MELCloud leser tilbake ved siden av det du valgte; er de ulike (for eksempel én time forskjøvet), sjekk i MELCloud-appen.
- Begge deler er større endringer enn å justere temperaturen, så appen ber deg bekrefte, og Claude må få godkjenning i vinduet på Macen. Funksjonene er ikke testet mot denne kontoen ennå: gjør den første endringen selv i appen og sjekk i MELCloud-appen at den er registrert.
- **Ukeplan**: er ukeplanen i MELCloud slått på, kan varmepumpen endre temperatur eller slå seg av og på etter planen. Appen viser planen, men kan ikke endre den.

## Fukt og lukt

- Rengjør luftfilteret hver 2. uke. Skitne filtre gir kondens og kan gi mugg.
- Lukter det rart, sjekk filtrene først.

## Strømpris

- Når strømmen er dyr noen timer (typisk morgen og ettermiddag), kan du heve ønsket temperatur 0,5–1 °C et par timer før, og senke like mye mens prisen er høy. Huset lagrer litt varme.
- Unngå store hopp (mer enn 2 °C) og å slå varmepumpen av og på for å spare. Hyppig av/på sliter på kompressoren, og det koster mer å varme opp igjen et nedkjølt hus.
- Med Norgespris er prisen lik hele døgnet; da sparer du mest på jevn, litt lavere temperatur. Nettleien er likevel lavere om natten og i helgene.
- Kostnaden appen viser er strøm + nettleiens energiledd − strømstøtte. Kapasitetsleddet (fastleddet) er ikke med, fordi det avhenger av hele husets høyeste forbruk.
- Prisnivå: Tibber merker hver time fra «svært billig» til «svært dyr» i forhold til snittet de siste dagene. Med andre spotkilder regner appen ut det samme mot snittet de siste 72 timene. Med Norgespris er prisen fast, så nivå vises ikke.

## Værvarsel og forvarming

Appen henter værvarsel fra MET Norway (yr.no) for huset, høyst én gang i timen. Værdata: MET Norway, CC BY 4.0.

- **Forvarming før kulde og dyre timer**: kommer en kald periode samtidig med høye priser, kan du heve ønsket temperatur med høyst 1 °C to–tre timer før, og sette den tilbake når perioden starter eller er over. Små steg er nok; huset holder på varmen en stund.
- **Unngå**: å skru mye opp og ned flere ganger om dagen, å slå varmepumpen av for å spare, og store hopp. Hyppige endringer gir kraftige starter og sliter på kompressoren, og et nedkjølt hus koster mer å varme opp igjen.
- **Vind og fukt**: sterk vind øker varmetapet; fuktig vær rundt 0 °C gir mer avriming. Begge deler kan øke forbruket litt uten at noe er galt.
- **Anslag for i morgen**: appen sammenligner forbruket mot hvor kaldt det har vært (graddager med grense 17 °C) i minst 10 av de siste 45 dagene, og bruker morgendagens varsel og priser. Det er et grovt anslag med et usikkerhetsområde, ikke et løfte.

## Lokale målinger (effekt og kompressor)

Når lokal tilkobling er slått på i appen, leser appen Wi-Fi-modulen direkte på hjemmenettet (bare lesing, aldri styring). Det gir:

- **Effekt (W)**: hva hele varmepumpen trekker akkurat nå. Rundt 4 W betyr at kompressoren står (bare elektronikk og vifte i hvile). Mens den varmer er 300–1200 W vanlig for denne størrelsen; mer når det er kaldt ute eller når den varmer opp et kaldt rom.
- **Kompressor (Hz)**: hvor hardt kompressoren jobber. 0 Hz betyr at den står. Lav, jevn frekvens over lang tid er det mest effektive.
- **Strømmåler**: en teller i pumpen med 0,1 kWh oppløsning. Den gir nøyaktig forbruk per time, så kostnaden blir eksakt (ikke anslag) for døgn appen har målt hele.
- **Kompressorstarter per time**: Én til tre starter i timen er normalt. Mange korte runder (fire eller flere i timen over flere timer) kalles korte sykluser og sliter på kompressoren. Se «Vedlikehold» for hva du kan gjøre.
- **Hva den gjør nå**: «Varmer», «Hviler (ønsket temperatur nådd)», «Forvarmer» (varmer opp før viften går for fullt, så den ikke blåser kaldt) eller «Avriser». Under avriming smelter utedelen bort is; innedelen blåser da lite eller kald luft i noen minutter. Det er normalt og skal ikke stoppes. Ikke endre innstillinger på grunn av en avriming.
- **Driftstid totalt**: innedelen teller minutter selv. Tallet er trolig total driftstid siden enheten ble satt i drift, men betydningen er ikke bekreftet av Mitsubishi.

Råd for styring ut fra effekt:

- Unngå å skru ønsket temperatur mye opp og ned. Hvert hopp gir en kraftig start med høy effekt.
- Er effekten høy over lang tid selv om det ikke er kaldt ute, sjekk luftfilteret og utedelen før du endrer innstillinger.
- Endepunktet i modulen er uoffisielt og kan slutte å virke etter en fastvareoppdatering. Da virker alt annet via MELCloud som før.

## Fastvareoppdatering

MELCloud gir beskjed når det finnes ny fastvare til Wi-Fi-modulen. Appen viser det under Helse → Fastvare, der du kan starte oppdateringen og følge den. Claude kan også starte den, men bare etter at du har godkjent det i dialogen på Macen.

- **Kan ikke angres**: en fastvareoppdatering kan ikke rulles tilbake når den først er startet.
- **Strøm og Wi-Fi**: varmepumpen må stå på strøm og ha godt Wi-Fi hele tiden. Ikke koble den fra strømnettet og ikke bruk fjernkontrollen mens oppdateringen pågår (MELCloud gir samme advarsel).
- **Tid**: oppdateringen kan ta en stund. Wi-Fi-modulen laster ned filer og starter på nytt; så lenge kan varmepumpen ikke styres fra appen eller MELCloud.
- **Bare eieren**: bare kontoen som eier enheten i MELCloud kan starte oppdateringen, og bare når enheten er tilkoblet.
- **Avbryte**: mens oppdateringen venter på enheten eller laster ned, kan den avbrytes i appen.
- **Ikke akutt**: start helst når du er hjemme og ikke trenger å endre noe den nærmeste timen.

## Sikkerhet

- R32 er et brennbart kjølemiddel. Ved mistanke om lekkasje: slå av, luft ut, ingen åpen flamme, ring forhandleren.
- Ikke stikk fingre eller gjenstander inn i luftinntak eller utblåsing.
- Ikke klatre på eller sett ting på utedelen.

## Om endringer via appen og Claude

- Alle endringer på varmepumpen krever at du godkjenner dem.
- Appen tillater maks 12 endringer per time og henter status maks én gang i minuttet, så MELCloud ikke stenger kontoen for mye trafikk.
