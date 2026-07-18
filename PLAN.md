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

### Phase 1 — RPCS3 compile pour iOS (aucune fonctionnalité encore)
- Fork `RPCS3/rpcs3` (master, contient déjà PPU+SPU arm64 LLVM).
- Merger/porter le fork asmjit requis (`RPCS3/asmjit#1`).
- Extraire un **CMake target headless** : couper la dépendance Qt (frontend
  desktop), ne garder que `rpcs3/Emu` (cœur émulation) + les libs core
  nécessaires, sur le modèle de ce qu'ARMSX2 a fait en coupant le Qt de
  PCSX2 pour iOS.
- Toolchain iOS (CMake + générateur Xcode, `arm64`, deployment target 17+),
  en reprenant `cmake/BuildParameters.cmake`/`Pcsx2Utils.cmake` d'AYS2 comme
  modèle de structure (pas le contenu, qui est PS2-spécifique).
- **Go/no-go** : un `.a`/`.framework` core RPCS3 headless link dans une app
  iOS vide, sans crash au démarrage.

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

## 6. État de la Phase 0

**Code posé, non testé sur device — c'est la prochaine étape immédiate.**

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
- [ ] **Go/no-go réel** : personne n'a encore appuyé sur "Run JIT stub
      probe" sur un iPhone. Tant que ce n'est pas fait, Phase 0 n'est pas
      validée — seulement compilée. Je n'ai pas de Mac/Xcode dans cet
      environnement pour tester moi-même l'exécution réelle ; ça ne peut
      venir que d'un test sur device par l'utilisateur
      (`docs/PHASE0_DEVICE_TESTING.md`).

Je n'ai pas encore lancé le clone de RPCS3 (dépôt lourd, dépendance LLVM,
build long) — Phase 1 attend que Phase 0 soit vérifiée go sur un vrai
device, comme prévu au plan initial.
