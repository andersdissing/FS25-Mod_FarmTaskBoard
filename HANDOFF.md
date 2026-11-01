# Handoff: FS25_FarmTaskBoard

Ny Farming Simulator 25-mod: en opgavetavle (kanban) pr. farm, med multiplayer-understøttelse. UI'et er godkendt via mockups i `mockups/`.

Ejer: Anders (Dissing Consulting). Repo: opret et privat GitHub-repo til modden, samme setup som FS25_CropRotationPlan.

## Status 2026-11-01 (v1.0.0.0, endnu ikke testet i spillet)

Alt i scope v1 er bygget i `Build/`. `tests/check_static.py` og `tests/smoke_test.py` (SP, MP med server og to klienter, tilskuer) er grønne. `tools/preview.py` tegner tavlen ud fra de stubbede kald til `Docs/preview/`, så layoutet kan sammenlignes med mockupperne.

Valg truffet undervejs:
- Esc-fanen installeres og afinstalleres med samme kode som CropYearWheelPlanner (bekræftet i spillet der). Fanen ligger lige over Indstillinger.
- Tavlen tegnes i Lua under spillets egen header, ligesom CYWP's sider. Tekstfeltet i dialogen er spillets eget `TextInput` (`fs25_textInput`, `maxCharacters=500`). Det placeres over dialogens tekstboks med `setAbsolutePosition` og har en tegntæller ved siden af.
- Esc annullerer først et træk, lukker derefter dialogen og lukker til sidst menuen. Esc i tekstfeltet annullerer dialogen. Q/E (forrige/næste side) er slået fra, mens dialogen er åben eller man trækker et kort (samme metode som FS25_ProductionAdvisor).
- Farm manager tjekkes med `g_farmManager:getFarmById(farmId):isUserFarmManager(userId)` på serveren. Brugeren findes ud fra forbindelsen (`userManager:getUserIdByConnection`), aldrig ud fra eventet.
- Serveren sender hele farmens tavle (`TaskBoardSyncEvent`) til alle klienter efter hver ændring. En afvist ændring sendes kun tilbage til afsenderen. Klienter modtager derfor også andre farmes tavler, men UI'et viser kun deres egen farm.
- Ved træk flytter klienten kortet med det samme. Afviser serveren, glider kortet tilbage, når synken kommer.
- Gemmes kun, når spillet gemmes (som i specifikationen).

Afvigelser fra specifikationen:
- Ghosten er ikke roteret -2°: `renderText` kan ikke rotere tekst. Den har alpha 0.7, skala 1.03 og en skygge.
- Højst 250 opgaver pr. farm, så synk og kolonner holdes i en fornuftig størrelse. Knappen "+ Ny opgave" er slået fra, når tavlen er fuld.
- Forkortede kort viser hele teksten som tooltip, når man holder musen over dem (relevant med 500 tegn).
- Kolonner med flere kort, end der er plads til, scrolles med musehjulet og viser "+N flere".
- "Synkroniseret med alle spillere" vises kun i multiplayer.

Skal tjekkes i spillet (ikke muligt i stub-testene):
1. Tekstfeltet: står det præcist over boksen, får det fokus, når dialogen åbner (`setForcePressed(true)`), og kan man skrive æøå? Lukker Esc/Enter i feltet dialogen uden også at lukke menuen?
2. Starter `TextInput` med en egen baggrund, der skal skjules?
3. Tavlens område under headeren (`headerPanel.absPosition`) og footeren over spillets knaplinje.
4. MP: rigtig dedikeret server med to klienter, join midt i spillet og samtidige træk.
5. `log.txt` for advarsler. Tysk og fransk er skrevet af Claude og bør læses igennem af en, der har sproget som modersmål.

## Mål

Farm manageren kan styre farmens opgaver i en tavle med tre kolonner. Alle deltagere på farmen kan se tavlen. Alle ændringer synkroniseres til alle spillere og gemmes med savegamet.

## Scope v1

- Tavlen er en fane i Esc-menuen (InGameMenu), navngivet "Opgaver". Der er ingen HUD eller anden in-game GUI i v1.
- Brug samme teknik som FS25_CropRotationPlan bruger til sin Esc-menu-fane. Genbrug kode og mønstre derfra, hvor det giver mening.
- Single player og multiplayer (dedikeret server og listen server).

## Datamodel

En tavle pr. farm (`farmId`).

Task:
- `id` (int): fortløbende nummer pr. farm. Tildeles af serveren som `nextId`, derefter `nextId + 1`. Numre genbruges aldrig, heller ikke efter sletning.
- `text` (string): en linje. Fjern linjeskift, trim mellemrum, maks. 500 tegn. Tom tekst afvises.
- `status` (enum): `0 = NOT_STARTED` ("Ikke startet"), `1 = TODO` ("Todo"), `2 = DONE` ("Færdig").
- `order` (int): placering i kolonnen. Rækkefølgen bevares ved træk.

Board pr. farm: `nextId`, liste af tasks.

## Rettigheder

- **Farm manager** kan oprette, rette tekst, ændre status, trække (flytte) og slette.
- **Andre deltagere på farmen** kan kun se. De har ingen "+ Ny opgave"-knap, ingen "Ret"-knapper og kan ikke trække kort. Footeren viser teksten "Kun farm manager kan oprette, rette, flytte og slette opgaver".
- Spillere ser kun tavlen for deres egen farm.
- Rettigheder håndhæves **på serveren**. Klientens UI skjuler kun knapperne. Serveren tjekker, om afsenderen er farm manager for den farm, opgaven hører til, før den udfører en ændring. Afviste requests ignoreres eller logges. FS22 havde `farm:isUserFarmManager(userId)`. Find den tilsvarende FS25-API i scriptdocs/LUADOC og brug den.

## Multiplayer

Ændringer går gennem server-autoritative events (FS25 `Event`-klasser med `writeStream`/`readStream`):

- `TaskBoardCreateEvent(farmId, text, status)`: serveren tildeler `id` og placerer opgaven sidst i kolonnen.
- `TaskBoardUpdateEvent(farmId, id, text, status)`
- `TaskBoardMoveEvent(farmId, id, newStatus, newOrder)`
- `TaskBoardDeleteEvent(farmId, id)`
- `TaskBoardSyncEvent(farmId, fullBoard)`: fuld tilstand fra server til klient.

Flow: klienten sender request → serveren validerer (rettighed, opgaven findes, tekstlængde maks. 500) → serveren opdaterer → serveren broadcaster den nye tilstand (enten deltaet eller en fuld sync for farmen) til alle klienter.

- Klienter, der joiner, får den fulde tilstand ved join.
- Samtidige ændringer: serveren behandler dem i rækkefølge. En request på en opgave, der er slettet i mellemtiden, ignoreres, og klienten får en fuld sync.
- Hvis serveren afviser et træk, glider kortet tilbage til sin oprindelige plads hos klienten.

## Persistens

- Gem i savegame-mappen, f.eks. `taskBoard.xml`, når spillet gemmes. Indlæs ved start på serveren.
- Hvis filen mangler, oprettes en tom tavle (`nextId = 1`). Brugeren skal ikke kopiere nogen filer manuelt.

Eksempel:

```xml
<taskBoard>
  <farm id="1" nextId="10">
    <task id="7" status="0" order="0" text="Kalk mark 23+25 før vintersæd"/>
    <task id="4" status="1" order="0" text="Pløj mark 6+7"/>
  </farm>
</taskBoard>
```

## UI (se `mockups/`)

Filer:
- `mockups/todo-mockup.html`: kilde. Man kan skifte tilstand med hash: `#dialog`, `#dialog,delconfirm` og `#readonly`.
- `mockup-tavle.png`: farm manager-visning midt i et træk.
- `mockup-ret-opgave.png`: dialogen "Ret opgave".
- `mockup-slet-opgave.png`: bekræftelse af sletning.
- `mockup-deltager.png`: visning for deltagere (kun læsning).

Layout:
- Header: titlen "Opgavetavle", knappen "+ Ny opgave" (kun farm manager) og et rolle-badge til højre ("Farm manager · navn" eller "Kun visning · navn (deltager)").
- Tre kolonner med samme bredde: Ikke startet (grå topkant), Todo (gul), Færdig (grøn). Kolonnens header viser antal opgaver.
- Kort: én linje med `#id` i grøn, teksten (forkortes med ellipsis) og en "Ret"-knap. Kortets venstre kant har kolonnens farve. Teksten på færdige kort er grå og overstreget.
- Footer: genvejstips og teksten "Synkroniseret med alle spillere".
- Hvis FS25's GUI-profiler ikke kan gengive mockuppen 1:1, prioriteres funktionen. Behold farverne pr. status og layoutet med tre kolonner.

Opret/ret-dialog (samme dialog til begge dele):
- Nummer: skrivebeskyttet. Ved ny opgave vises "Ny".
- Tekst: tekstfelt på én linje, maks. 500 tegn. Ved siden af feltet vises en tegntæller (`123/500`), der opdateres mens man skriver.
- Status: tre knapper (Ikke startet / Todo / Færdig). Ny opgave starter som "Ikke startet". Status kan ændres ved både oprettelse og redigering.
- Knapper: "Slet opgave" (rød, venstre, kun ved redigering), "Annuller", "Gem".
- Sletning viser en bekræftelse inde i dialogen: `Slet opgave #N "tekst"? Det kan ikke fortrydes.` med knapperne "Annuller" og "Slet". Der slettes kun én opgave ad gangen og ingen massesletning.
- Dobbeltklik på et kort åbner også dialogen (kun farm manager).

Færdige opgaver bliver stående, indtil de slettes. Der er ingen automatisk oprydning.

## Drag and drop med animation

FS25's GUI har ingen indbygget drag and drop. Implementer det med mouse events på kort-elementerne:

1. **Start:** museknap ned + bevægelse over ~5 px på et kort. Kortet bliver liggende på sin plads med alpha ~0.25.
2. **Træk:** en kopi af kortet ("ghost") følger musen. Den har alpha ~0.7, er roteret ca. -2°, skaleret 1.03 og har skygge, hvis GUI'et tillader det. Ghosten er gennemsigtig, så man kan se, hvad der ligger under den.
3. **Mål:** den kolonne, musen er over, får grøn kant og svag grøn baggrund. En stiplet pladsholder viser, hvor kortet lander (mellem kortene). De øvrige kort glider til side (tween ~150-250 ms).
4. **Slip:** ghosten glider ind på pladsholderens plads (~200 ms ease-out), og så sendes `TaskBoardMoveEvent`. Slip uden for en kolonne eller Esc annullerer, og kortet glider tilbage.
5. Træk inden for samme kolonne ændrer kun `order`.

Træk er kun aktivt for farm manager.

## Lokalisering

`l10n` til dansk (`da`), engelsk (`en`), tysk (`de`) og fransk (`fr`) i henhold til FS25's retningslinjer for mods. Danske tekster som i mockupperne. Engelsk er fallback.

## Ikke i scope v1

- HUD eller minimeret visning in-game.
- Controller- og gamepad-navigation (kun mus/tastatur).
- Tildeling af opgaver til spillere, deadlines og kobling til marker.
- Massesletning og arkiv.

## Acceptkriterier

1. Fanen "Opgaver" vises i Esc-menuen i både SP og MP.
2. Farm manageren kan oprette en opgave. Den får det næste nummer og vises med det samme hos alle spillere på farmen.
3. Farm manageren kan rette tekst og status i dialogen. Status flytter kortet til den rigtige kolonne.
4. Træk mellem og inden for kolonner virker med animationen beskrevet ovenfor, og resultatet synkroniseres.
5. Sletning kræver bekræftelse og fjerner kun den ene opgave. Numre genbruges ikke.
6. En deltager uden farm manager-rettighed kan se alt og kan ikke ændre noget. En manipuleret klient-request afvises af serveren.
7. Tavlen overlever gem/indlæs og server-genstart. En spiller, der joiner, ser den aktuelle tavle.
8. Et nyt savegame uden `taskBoard.xml` starter med en tom tavle uden fejl i log.txt.

## Test

- SP: opret, ret, træk, slet, gem, genindlæs.
- MP med to klienter (en manager og en deltager): synk, rettigheder, join midt i spillet, samtidige træk.
- Tjek `log.txt` for Lua-fejl og advarsler.
