# Strømmåleren (Tibber)

Appen henter husets strømforbruk fra Tibber med den samme personlige nøkkelen som Tibber-prisene bruker.

## Forbruk per time

- Tibber oppgir hele husets forbruk per time, med Tibbers egen kostnad for hver time.
- Dataene kommer ikke i sanntid: de siste timene kommer ofte 2–3 timer forsinket, og en time som ikke er ferdig, er ikke med. Appen spør Tibber høyst én gang i timen.
- Appen priser hver time som ellers i appen: strømavtalen din, nettleiens energiledd og strømstøtten. Tibbers egen kostnad har ikke med nettleie, så de to blir forskjellige.

## Effekt nå

- Effekt nå krever en sanntidsmåler koblet til hjemmet i Tibber-appen (Tibber Pulse eller Watty). Uten den vises bare forbruket per time.
- Måleren sender en ny verdi med noen sekunders mellomrom; hvor ofte avhenger av strømmåleren.
- Effekt nå leses bare mens appen er åpen og måleren er slått på. Appen holder én tilkobling til Tibber og setter den på pause mens Macen sover.
- Dagens forbruk så langt kommer fra målerens teller siden midnatt til Tibbers timedata har tatt igjen.

## Varmepumpens andel

Med en varmepumpe i appen vises husets forbruk ved siden av varmepumpens, så du ser hvor mye av husets strøm varmepumpen bruker. Andelen vises for døgn der begge er kjent i minst 20 timer.

## Greit å vite

- Tibber begrenser hvor ofte apper kan spørre. Appen holder seg langt under grensen, og en nøkkel som er avvist, prøves ikke igjen før du lagrer en ny.
- Nøkkelen lagres i nøkkelringen på denne Macen.
