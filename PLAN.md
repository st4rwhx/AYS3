# AYS3 — Plan d'ingénierie (PS3 sur iOS)

Écrit après recherche complète (voir `RESEARCH.md`). Ce document assume le
rôle d'un ingénieur émulation senior : honnête sur ce qui est faisable, ce
qui est incertain, et ce qui prendra du temps — pas un plan marketing.

## 0. Verdict avant tout

**"One-shot" un émulateur PS3 iOS complet et fluide n'est pas réaliste.**
Ce qu'on peut "one-shot", c'est la stratégie et la première brique vérifiable.
Trois raisons concrètes, pas de la prudence gratuite :

1. **On n'a pas de socle prêt.** Contrairement à AYS2 (reskin d'ARMSX2, un
   moteur ARM64 déjà mature), il n'existe **aucun** "RPCS3 pour ARM64
   mobile" publié par qui que ce soit. On serait la première équipe à
   porter Cell BE + RSX sur iOS. RPCS3 lui-même a mis 10 ans à devenir
   utilisable sur desktop, avec une équipe dédiée et du matériel x86 rapide.
2. **Le chemin ARM64 qui existe déjà dans RPCS3 (mergé, PR #12115 + #12338)
   est le chemin lent** : LLVM recompiler, pas ASMJIT. ASMJIT (le vrai
   moteur de perf de RPCS3 pour le SPU) est x86-only et personne ne l'a
   porté ARM64. Le Cell BE tourne déjà à la limite du jouable sur des PC
   récents pour une partie de la ludothèque — sur un SoC de téléphone, avec
   le chemin lent, une fraction significative des jeux risque d'être
   injouable même en supposant que tout compile et boot correctement.
3. **Le JIT iOS est un hack fragile, pas une fondation stable.** La
   technique dual-map + TXM (`brk #0xf00d`, StikDebug) a déjà changé une
   fois avec iOS 26 et est nommée "Luck" par ses propres auteurs. On bâtit
   dessus parce que c'est le seul chemin qui existe, en sachant qu'une future
   version iOS peut la casser sans préavis.

Le bon objectif réaliste : **une campagne en phases, chacune avec un
critère go/no-go vérifiable sur device**, pas une conquête en un seul commit.

## 1. Legal / éthique (à verrouiller avant tout, pas après)

- RPCS3 est **GPLv2**. Un fork iOS est une œuvre dérivée : le code source
  complet du fork doit rester disponible sous GPLv2 à quiconque reçoit
  l'app (obligation légale réelle, pas cosmétique). Attribution/NOTICE
  obligatoire, comme prévu pour ARMSX2 dans AYS2.
- **Aucun firmware PS3, aucune ISO ne sera jamais commité, distribué ou
  lié en téléchargement** dans ce repo ou l'app. L'app doit dumper le
  firmware depuis un vrai PS3 possédé par l'utilisateur (ou installer via
  un PUP officiel Sony que l'utilisateur fournit lui-même), exactement
  comme RPCS3 desktop le fait déjà. Même règle pour les jeux : l'utilisateur
  dump ses propres disques.
- Distribution via sideload uniquement (StikDebug/AltStore/SideStore/
  TrollStore), jamais App Store (Apple interdit les émulateurs à JIT tiers
  de toute façon, et le contournement JIT viole les règles App Store).

## 2. Architecture cible

```
┌───────────────────────────────────────────┐
│      iOS UI (SwiftUI)                      │
│  Bibliothèque jeux, import BIOS/ISO,       │
│  savestates, réglages, StikDebug bootstrap │
└──────────────────┬──────────────────────────┘
┌──────────────────▼──────────────────────────┐
│   Bridge Objective-C++ (EmulatorBridge)      │
│   Swift ↔ C++, textures partagées, input     │
└──────────────────┬──────────────────────────┘
┌──────────────────▼──────────────────────────┐
│   Core RPCS3 (fork) — headless, sans Qt      │
│   PPU (LLVM arm64, PR #12115)                │
│   SPU x1-6 (LLVM arm64, PR #12338)           │
│   RSX → Vulkan → MoltenVK → Metal            │
│   Allocateur JIT = MmapCodeDualMap            │
│   (repris tel quel de AYS2/DarwinMisc.cpp)   │
└──────────────────┬──────────────────────────┘
┌──────────────────▼──────────────────────────┐
│   JIT bypass : StikDebug + script            │
│   (universal.js / script dédié "ays3.js")    │
└───────────────────────────────────────────────┘
```

Différence clé avec AYS2 : chez AYS2, le "Core RPCS3-équivalent" (ARMSX2)
existait déjà tout fait. Ici, la case "Core RPCS3 (fork)" est le vrai
chantier — tout le reste (bridge, UI, JIT bypass) est du pattern déjà
prouvé qu'on peut réutiliser à l'identique.

## 3. Phases

### Phase 0 — Preuve de faisabilité JIT (isolée, avant tout RPCS3)
**But : valider le contournement JIT sur un cas trivial avant d'investir
dans l'intégration RPCS3.**

- App SwiftUI minimale, entitlements identiques à AYS2
  (`get-task-allow`, `com.apple.security.cs.allow-jit`,
  `allow-unsigned-executable-memory`).
- Réutiliser tel quel `DarwinMisc.cpp` (détection TXM, `MmapCodeDualMap`,
  `JIT26PrepareRegion`/`Detach`) — code déjà validé sur iPhone 15 / iOS 26.3.
- Écrire à la main (pas via LLVM) quelques instructions arm64 dans la
  région JIT et les exécuter (ex: fonction qui retourne 42).
- Script StikDebug dédié (`ays3.js`, copie adaptée d'`universal.js`).

**Go/no-go** : le stub JIT s'exécute sur device réel via StikDebug. Si non
→ on s'arrête là, tout le reste est inutile tant que ce n'est pas résolu.

### Phase 1a — LLVM cross-compile pour iOS (démarrée 2026-07-18)
**Découverte importante en démarrant Phase 1** : `external/rpcs3/3rdparty/llvm/CMakeLists.txt`
confirme que RPCS3 n'embarque PAS LLVM par défaut (`BUILD_LLVM OFF`) — sur
desktop il utilise un LLVM précompilé (Homebrew, paquet système, ou
libs Windows précompilées). **Il n'existe aucun équivalent "LLVM
précompilé pour iOS"** : on doit construire LLVM soi-même, croisé pour
`arm64-apple-ios`, pour qu'il tourne comme bibliothèque DANS l'app iOS
(pas juste comme toolchain de compilation — RPCS3 a besoin de LLVM comme
JIT *hébergé sur la cible*). Ni RPCS3 (arm64 = desktop uniquement) ni
ARMSX2 (n'utilise pas LLVM, recompileur ARM64 écrit à la main) n'ont
défriché ça. C'est probablement un déverrouillage aussi fondamental que le
contournement JIT de la Phase 0 — donc, même méthode : l'isoler et le
valider seul avant de toucher au reste de RPCS3.

Bonne nouvelle trouvée dans le même fichier : RPCS3 a déjà une branche
`if (ANDROID) ... set(LLVM_TARGETS_TO_BUILD "AArch64" ...)` — donc
croiser leur build LLVM pour une cible mobile ARM64 non-desktop est un
chemin déjà emprunté par leur propre CMake, pas une invention totale.

- `external/rpcs3` ajouté comme submodule Git (pointeur de commit, pas de
  contenu vendored dans AYS3 — voir `.gitmodules`). Seuls
  `3rdparty/llvm/llvm` (le monorepo LLVM, ~2 Go même en shallow) et
  `3rdparty/asmjit/asmjit` sont initialisés ; les ~40 autres submodules
  (Qt-adjacent, ffmpeg, audio...) ne le sont pas — inutiles à ce stade.
- `tools/llvm-ios-probe/` : projet CMake isolé qui croise UNIQUEMENT
  LLVM (Core + cible AArch64 + ORC JIT, sans tools/tests/docs/exemples —
  même périmètre que RPCS3) pour `arm64-apple-ios`, et lie un exécutable
  `probe.cpp` qui construit une fonction IR triviale et l'exécute via
  `LLJIT`. Le code C++ a été compilé et **exécuté avec succès en natif
  sur Linux/x86_64** contre LLVM 19.1.1 avant d'être poussé (`ays3_probe()
  = 42`) — l'API ORC est donc correcte ; ce qui reste incertain est
  purement la compilation croisée de LLVM lui-même pour iOS.
- CI dédiée (`llvm-ios-probe.yml`, déclenchée sur push scopé à son dossier
  + `workflow_dispatch`, timeout 350 min).

**Run #1 (2026-07-18) — échec après ~4min30 de config seulement (pas un
build raté, une vraie découverte) :**
- `CMake Error ... TableGen.cmake:239 (install): install TARGETS given no
  BUNDLE DESTINATION for MACOSX_BUNDLE executable target "llvm-tblgen"`.
- Diagnostic fait en lisant directement le code LLVM vendored (pas deviné) :
  le générateur **Xcode** force la sémantique "app bundle" sur tout
  exécutable dès que `CMAKE_SYSTEM_NAME=iOS` — correct pour notre vraie
  app (Phase 0), mais cassé pour un outil de build interne comme
  `llvm-tblgen`, qui n'est pas censé être une app iOS du tout.
- Ce même run confirmait aussi, en le nommant explicitement dans ses logs
  ("Setting native build dir to .../NATIVE"), le risque anticipé : LLVM
  sait qu'il doit faire tourner TableGen sur la machine hôte, mais son
  mécanisme auto (`LLVM_USE_HOST_TOOLS`) réutilise le générateur du build
  parent (`-G Xcode`) — donc hérite du même problème en cascade.
- **Correctif appliqué (deux volets, mêmes causes réelles trouvées ci-dessus,
  pas une supposition) :**
  1. Le cross-build LLVM passe de `-G Xcode` à **`-G Ninja`** (pas de
     notion de bundle pour un exécutable simple) — via un toolchain file
     dédié `tools/llvm-ios-probe/ios-ninja-toolchain.cmake` (SDK iOS
     résolu via `xcrun`, `CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY`
     comme tous les toolchains iOS/Android CMake connus). L'app AYS3
     réelle (Phase 0) reste sur `-G Xcode` — seule la dépendance LLVM
     change de générateur, ce sont deux configure CMake distincts.
  2. Un **stage 1 séparé** construit `llvm-tblgen`/`llvm-min-tblgen`
     nativement (Ninja, host macOS, pas de toolchain iOS) avant le stage 2
     (cross iOS), qui pointe dessus via `LLVM_NATIVE_TOOL_DIR` — exactement
     le mécanisme que LLVM documente lui-même pour ce cas
     (`CrossCompile.cmake`), fait explicitement plutôt que de compter sur
     l'automatisme qui vient de casser.

**Run #2 (2026-07-18) — le stage 1 (natif) a marché du premier coup**
(`llvm-tblgen`/`llvm-min-tblgen` compilés et linkés en moins d'une minute,
273/273 cibles) — la partie qu'on redoutait le plus s'est avérée simple.
Le stage 2 (cross iOS) a cassé immédiatement, mais sur une bête erreur à
nous, pas sur LLVM : notre propre garde `if(NOT CMAKE_SYSTEM_NAME STREQUAL
"iOS") message(FATAL_ERROR ...)` était placée **avant** l'appel à
`project()` dans `tools/llvm-ios-probe/CMakeLists.txt`. Or
`CMAKE_TOOLCHAIN_FILE` (et donc `CMAKE_SYSTEM_NAME=iOS` qu'il définit)
n'est traité par CMake que pendant le premier `project()` — avant ça, la
variable vaut encore la valeur hôte native ("Darwin"), donc notre garde
se déclenchait à tous les coups, peu importe le toolchain passé en ligne
de commande. Corrigé en déplaçant `project()` avant la vérification.
Vérifié en plus, en lisant `llvm/CMakeLists.txt` : `add_subdirectory(utils/TableGen)`
(qui définit `llvm-tblgen`/`llvm-min-tblgen` et lit `LLVM_NATIVE_TOOL_DIR`)
n'est **pas** conditionné par `LLVM_INCLUDE_UTILS` (contrairement aux
autres utils) — donc `LLVM_INCLUDE_UTILS=OFF`/`LLVM_BUILD_UTILS=OFF` dans
notre CMake ne casse pas le mécanisme de substitution vers le tblgen
natif ; pas besoin de revenir dessus.

**Run #3 (2026-07-18) — le vrai build a tourné, 1629/1630 étapes en succès :**
`libLLVMCore`, `libLLVMAArch64CodeGen`, `libLLVMAArch64AsmParser`,
`libLLVMOrcJIT`, `libLLVMExecutionEngine`, `libLLVMJITLink`, tout le reste
— compilés pour `arm64-apple-ios` en ~14 min (stage 2 seul). C'est la
preuve empirique que ce que la Phase 1a devait établir est vrai : LLVM se
compile pour tourner comme bibliothèque hébergée sur iOS, pas seulement
comme toolchain ciblant iOS. Seule la toute dernière étape (le link de
`ays3_llvm_probe`) a cassé : `ld: library 'rt' not found` — `librt`
n'existe pas sur Darwin (ces symboles POSIX temps-réel vivent dans
libSystem), contrairement à Linux d'où vient cette dépendance résolue par
`llvm_map_components_to_libnames`. **Le job CI s'est pourtant affiché
"success"** : le script utilisait `cmake --build ... | tee build_ios.log`
sans `set -o pipefail`, donc l'échec du build était masqué par le code de
sortie de `tee` (toujours 0). Corrigé sur les deux fronts : `list(REMOVE_ITEM
AYS3_LLVM_LIBS rt)` dans le CMake du probe, et `set -o pipefail` ajouté à
toutes les étapes de build/configure de `llvm-ios-probe.yml` (pas
seulement celle qui vient de mentir) pour ne plus jamais se faire avoir
par un faux vert sur ce workflow.

**Run #4 (2026-07-18) — `set -o pipefail` a fait son travail : échec
signalé correctement cette fois, sur exactement la même erreur `-lrt`.**
Le correctif du run #3 (`list(REMOVE_ITEM AYS3_LLVM_LIBS rt)`) ne
touchait pas la vraie source : "rt" n'est pas dans notre liste, il est
ajouté de façon transitive par `libLLVMSupport` lui-même
(`llvm/lib/Support/CMakeLists.txt` : `if(HAVE_LIBRT) set(system_libs
${system_libs} rt) endif()`). `HAVE_LIBRT` vient de
`check_library_exists(rt clock_gettime "" HAVE_LIBRT)` dans
`config-ix.cmake`, qui réussit à tort ici : notre toolchain iOS force
`CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY` (nécessaire pour que
d'autres vérifications marchent en cross-compilation), donc ce check ne
lie jamais vraiment un exécutable contre `-lrt` — il compile juste une
`.a`, ce qui réussit toujours, que `librt` existe ou non. Corrigé en
préemptant le cache : `set(HAVE_LIBRT OFF CACHE BOOL ... FORCE)` avant
`add_subdirectory(llvm)` — `check_library_exists()` saute son propre test
si la variable est déjà en cache, donc ça court-circuite le faux positif
à la source plutôt que de patcher le symptôme.

- **Go/no-go 1a** : `ays3_llvm_probe` compile et link pour arm64-apple-ios
  en CI — **en attente de confirmation du run #5** avec le vrai fix
  `HAVE_LIBRT`. Tout le reste (les 1629 autres étapes) est acquis depuis
  le run #3. (L'exécution réelle sur device, comme pour la Phase 0,
  restera une étape séparée — un binaire iOS ne tourne pas sur le runner
  macOS qui le compile.)

### Phase 1b — RPCS3 core compile pour iOS (aucune fonctionnalité encore)
- Fork `RPCS3/rpcs3` (master, contient déjà PPU+SPU arm64 LLVM) — fait,
  submodule `external/rpcs3`.
- Merger/porter le fork asmjit requis (`RPCS3/asmjit#1`) si besoin — à
  vérifier une fois 1a validée (RPCS3 target ARM64 SPU utilise le chemin
  LLVM, pas ASMJIT, donc peut-être pas bloquant pour un premier boot).
- Extraire un **CMake target headless** : couper la dépendance Qt (frontend
  desktop), ne garder que `rpcs3/Emu` (cœur émulation) + les libs core
  nécessaires, sur le modèle de ce qu'ARMSX2 a fait en coupant le Qt de
  PCSX2 pour iOS.
- Toolchain iOS (CMake + générateur Xcode, `arm64`, deployment target 17+),
  en reprenant `cmake/BuildParameters.cmake`/`Pcsx2Utils.cmake` d'AYS2 comme
  modèle de structure (pas le contenu, qui est PS2-spécifique).
- **Go/no-go** : un `.a`/`.framework` core RPCS3 headless link dans une app
  iOS vide, sans crash au démarrage.

**Reconnaissance faite pendant l'attente de la CI Phase 1a (2026-07-18),
inspection directe du code RPCS3 vendored — pas de supposition :**
- RPCS3 a déjà un point d'entrée "headless" (`rpcs3/headless_application.h`,
  `main_application.cpp`), utilisé pour ses builds CLI/serveur sans
  interface graphique (`rpcs3qt/`). **Mais "headless" chez RPCS3 ne veut
  pas dire "sans Qt"** : `headless_application` hérite de
  `QCoreApplication` (event loop, signaux/slots inter-thread via
  `RequestCallFromMainThread`) — seul QtWidgets/QtGui est écarté, pas
  QtCore. Confirmé : `CMakeLists.txt` n'a **aucune option `WITH_QT`** —
  Qt (au moins QtCore) est une dépendance non-optionnelle du binaire
  `rpcs3`, contrairement à `WITH_LLVM`/`USE_VULKAN`/etc. qui sont tous
  des options.
- Donc "couper Qt" (ligne ci-dessus) est plus gros que prévu : soit (a)
  compiler QtCore (pas QtWidgets) pour iOS — Qt supporte officiellement
  iOS depuis longtemps, donc c'est un problème déjà résolu par quelqu'un
  d'autre, contrairement à LLVM-sur-iOS (Phase 1a) — soit (b) retirer la
  dépendance `QCoreApplication` du cœur RPCS3 et réimplémenter nous-mêmes
  la boucle d'événements/le mécanisme cross-thread minimal dont
  `main_application`/`VMManager` ont besoin. (a) est probablement le
  chemin le moins risqué (dépendance connue et déjà portée iOS par Qt
  lui-même) mais ajoute Qt-pour-iOS comme brique supplémentaire du plan —
  à trancher une fois 1a validé, pas avant.
- Confirmé aussi : `option(USE_VULKAN "Vulkan render backend" ON)` et
  `option(USE_SYSTEM_MVK "Prefer system MoltenVK...")` — cohérent avec
  `RESEARCH.md` (RSX → Vulkan → MoltenVK, pas de renderer Metal natif).

### Phase 2 — Boot PPU seul, interpréteur, sans RSX
- Firmware PS3 réel (dumpé par l'utilisateur) chargé et déchiffré par le
  code RPCS3 existant (aucune réécriture nécessaire ici, c'est portable).
- PPU en mode **interpréteur** uniquement (le plus lent mais le plus simple
  à debugger) — objectif : atteindre les premiers syscalls du firmware sans
  crash, logs de boot cohérents. Renderer "null" (pas d'image).
- **Go/no-go** : logs de boot du firmware progressent normalement (mêmes
  étapes que sur desktop RPCS3), pas de crash sur les premiers milliers
  d'instructions PPU.

### Phase 3 — RSX / affichage
- Empaqueter MoltenVK pour iOS (Khronos fournit un build iOS de MoltenVK —
  à vérifier/adapter, jamais testé avec une charge RSX).
- Brancher le renderer Vulkan existant de RPCS3 sur cette MoltenVK iOS.
  Attendre des crashs liés à des hypothèses desktop (création de surface,
  extensions Vulkan absentes sur iOS, layout mémoire) — c'est
  probablement la phase la plus imprévisible du plan en durée.
- **Go/no-go** : une image (même l'écran "PS3 System Software Update" ou le
  XMB) s'affiche à l'écran, à n'importe quel framerate.

### Phase 4 — Activer le JIT (PPU + SPU LLVM), perf réelle
- Remplacer l'interpréteur par les recompileurs LLVM arm64 (PR #12115 /
  #12338), en redirigeant leur allocation mémoire exécutable vers
  `MmapCodeDualMap` (Phase 0) au lieu du `mmap(MAP_JIT)` desktop standard.
  Ça implique d'écrire un memory manager LLVM (ORC/MCJIT) custom — pas
  juste un flag à cocher.
- Threads SPU (jusqu'à 6) : réfléchir l'ordonnancement pour un SoC mobile
  (moins de cœurs physiques que le budget "idéal" PS3 : PPU + 6 SPU + RSX
  + audio + OS en même temps). Time-slicing ou réduction du nombre de SPU
  simulés en parallèle à évaluer empiriquement.
- **Go/no-go** : un jeu commercial (pas une homebrew de test) boote jusqu'au
  menu, à n'importe quel framerate, sans crash en 10 minutes.

### Phase 5 — Stabilité, mémoire, savestates, UX
- Gestion mémoire vs jetsam iOS (cache de shaders RPCS3 connu pour monter à
  plusieurs Go sur desktop — budget à revoir drastiquement à la baisse ou
  streaming/éviction agressive).
- Savestates : la fonctionnalité est déjà marquée expérimentale sur RPCS3
  desktop pour une partie des jeux ; s'attendre à ce que ce soit pire au
  début sur le fork iOS. Ne pas promettre la fiabilité savestate en Phase 5.
- UI bibliothèque de jeux, gestion BIOS/ISO/saves, réglages (reprendre le
  pattern MVVM SwiftUI d'AYS2 : `RootView`/`GameListView`/`EmulatorView`).

### Phase 6 — Distribution
- Feed SideStore/AltStore (reprendre le pattern Cloudflare Worker
  `source/worker` d'AYS2), script StikDebug dédié versionné avec l'app,
  NOTICE GPLv2 + attribution RPCS3, avertissement clair "dump tes propres
  jeux/firmware" dans le README et dans l'app.

## 4. Registre de risques (à ne pas balayer sous le tapis)

| # | Risque | Impact | Statut |
|---|---|---|---|
| 1 | Dual-map/TXM cassé par une future iOS | Bloquant total | Dépendance externe, hors de notre contrôle |
| 2 | Chemin LLVM (pas ASMJIT) trop lent sur SoC mobile pour du gameplay temps réel | Une partie significative des jeux injouable | Inconnu tant que Phase 4 n'est pas testée |
| 3 | RSX via MoltenVK-iOS jamais testé en conditions PS3 | Durée Phase 3 imprévisible, perf inconnue | Inconnu |
| 4 | Mémoire (shader cache, JIT cache) vs jetsam iOS | Crashs aléatoires en jeu | À mesurer dès Phase 3-4 |
| 5 | Thermal throttling iPhone sous charge Cell BE+RSX soutenue | Perf qui chute après quelques minutes | Attendu, à mesurer |
| 6 | Obligations GPLv2 non respectées | Risque légal/retrait | Verrouillé dès Phase 0 (voir §1) |
| 7 | Bus factor (projet solo vs équipe RPCS3/ARMSX2) | Vitesse d'avancement | Accepter un calendrier long, pas "one-shot" |
| 8 | LLVM cross-compilé pour tourner *sur* iOS (pas juste compiler *pour* iOS) n'a jamais été fait publiquement pour RPCS3 ni ARMSX2 | Peut bloquer toute la Phase 1b si ça ne compile pas | En cours de test isolé, Phase 1a — voir §3 |

## 5. Ce qu'on réutilise telle quelle (ne pas réinventer)

- `AYS2/src/cpp/common/Darwin/DarwinMisc.cpp` — détection TXM + allocateur
  JIT dual-map, déjà validé sur device.
- `AYS2/src/cpp/Entitlements.plist` — jeu d'entitlements minimal qui marche.
- Scripts StikDebug (`universal.js` / `UTM-Dolphin.js`) — juste les adapter
  au bundle id d'AYS3.
- Le pattern SwiftUI/MVVM + bridge Obj-C++ d'AYS2 (`EmulatorBridge`,
  `AppState`, `SettingsStore`) comme squelette de code, à re-typer pour un
  cœur RPCS3 au lieu de PCSX2.
- Le pattern de distribution SideStore/Cloudflare Worker d'AYS2.

## 6. État de la Phase 0 — VALIDÉE sur device réel (2026-07-18)

- [x] App SwiftUI squelette (`src/swift/AYS3App.swift`, `ContentView.swift`)
- [x] Entitlements (`get-task-allow`, `cs.allow-jit`,
      `allow-unsigned-executable-memory`) — identiques à AYS2.
- [x] `JITBypass.h`/`.cpp` — extraction standalone du mécanisme dual-map/TXM
      d'AYS2 (`DarwinMisc.cpp`), sans les dépendances PCSX2 dont on n'a pas
      besoin ici. Même protocole `brk #0xf00d`/`brk #0x69`, même logique
      `vm_remap`, préservés à l'identique — c'est la partie qui ne doit
      surtout pas être réinventée à la légère (voir `RESEARCH.md` §4).
- [x] CMake + générateur Xcode (`src/cpp/CMakeLists.txt`), CI macOS
      (`.github/workflows/build-ios.yml`) qui produit un IPA non signé.
- [x] Protocole de test device (`docs/PHASE0_DEVICE_TESTING.md`) : sideload,
      pairing StikDebug, activation JIT, lecture du résultat.
- [x] **CI verte** : run #2 (commit `7e7b9bf`, 2026-07-18) compile et
      package `AYS3.ipa` sur runner macOS arm64 GitHub Actions
      (Xcode 16.2 / iOS SDK 18.2). Run #1 avait échoué — `xcodebuild`
      cherchait `AYS3iOS.xcodeproj` alors que CMake générait `AYS3.xcodeproj`
      (le générateur Xcode nomme le projet d'après `project()`, pas
      d'après la cible) ; corrigé en renommant le projet CMake en
      `AYS3iOS`. Ça prouve seulement que **ça compile** — pas que le
      contournement JIT marche.
- [x] **Go/no-go réel — PASS.** Testé sur device réel par l'utilisateur via
      StikDebug (screenshots, 2026-07-18) :
      - `CS_DEBUGGED=1`, `jit_mode=LuckTXM` (confirme un SoC A15+ sous iOS 26+).
      - `mmap(MAP_JIT)` direct échoue bien (err=1/EPERM) comme attendu pour
        un process `get-task-allow` non entitled `dynamic-codesigning` —
        confirme qu'on tombe correctement dans le chemin dual-map.
      - Handshake `brk #0xf00d` (prepare-region **et** detach) acquitté par
        StikDebug — le PIP StikDebug le confirme côté debugger : "BRK
        immediate: 0xf00d (61453)", "Invoking command 0", "detachResponse
        = OK". Notre convention x16=0/1 correspond exactement à ce que
        StikDebug attend.
      - Dual-map établi : `rx=0x105890000` / `rw=0x105894000` (offset
        0x4000, une page à part — cohérent avec `vm_remap`).
      - Le stub écrit dans la vue RW s'exécute via la vue RX :
        `stub returned 42 (expected 42)` → **RESULT: PASS**.
      - **Ce que ça prouve** : le contournement JIT n'est pas juste
        théorique/copié d'AYS2 — il est vérifié fonctionnel de bout en
        bout, sur silicium réel, avec notre extraction standalone. C'est la
        seule fondation sans laquelle tout le reste du plan n'a pas de
        sens (§0) — elle tient.
      - **Ce que ça ne prouve pas** : la robustesse dans la durée (risque
        #1 du registre) — un seul device/version iOS testé jusqu'ici.
      - **Device confirmé** : iPhone 15 (A16, donc TXM présent — cohérent
        avec `LuckTXM`), iOS 26.3. Premier point de données réel du
        registre de risques §4 (risque #1) — une future version iOS reste
        susceptible de casser ce chemin, mais on sait maintenant qu'il
        fonctionne au moins sur cette combinaison précise.

Phase 0 est go, confirmé le 2026-07-18 (iPhone 15 / iOS 26.3). **Phase 1
démarrée** ci-dessous.
