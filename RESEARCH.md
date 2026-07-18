# AYS3 — État de l'art (recherche, juillet 2026)

Recherche menée avant tout code. Objectif : savoir exactement sur quoi on peut
s'appuyer, et sur quoi on serait seuls.

## 1. Personne n'a fait "RPCS3 pour iOS"

- RPCS3 officiel (rpcs3.net) : Windows / Linux / macOS / FreeBSD uniquement.
- L'équipe RPCS3 a publiquement expliqué pourquoi elle ne portera **pas**
  vers Android/iOS elle-même : harcèlement subi par d'autres devs mobiles
  (ex. AetherSX2), et surtout la prolifération d'applis "RPCS3 mobile"
  frauduleuses/malware sur les stores.
  <https://www.notebookcheck.net/RPCS3-team-shares-why-the-PS3-emulator-won-t-land-on-Android-and-iOS-anytime-soon.930245.0.html>
- RPCS3 a publié un **avertissement officiel** : toute appli "RPCS3 iOS/Android"
  est une arnaque, aucune n'est légitime.
  <https://www.timeextension.com/news/2024/09/rpcs3-issues-warning-about-ps3-scam-emulators-for-mobile>
  <https://www.retronews.com/rpcs3-warns-against-ps3-scam-emulators-for-mobile-users/>
- Vérifié : les sites "RPCS3 for iOS" (xevod.com, apkod.com, ps3mobi.com,
  ps3emulator.altervista.org...) décrivent même RPCS3 comme écrit "en C#"
  (faux — RPCS3 est en C++). Signal net de contenu généré/arnaque. À ignorer
  et à ne surtout pas utiliser comme base.
- **Conclusion : il n'existe aucun "ARMSX2 de RPCS3".** Contrairement à AYS2
  (qui reskin un moteur ARM64 déjà mûr, ARMSX2), un émulateur PS3 iOS serait
  un projet inédit. C'est le point le plus important de cette recherche.

## 2. Ce qui existe côté RPCS3 et qu'on PEUT récupérer

- Déc. 2024, RPCS3 annonce le support **arm64 natif** (Linux, macOS, Windows
  arm64 — pas iOS) : <https://blog.rpcs3.net/2024/12/09/introducing-rpcs3-for-arm64/>
- Le travail arm64 vient de deux PR de **sguo35**, mergées dans
  `RPCS3/rpcs3` (master) :
  - PPU LLVM arm64+macOS — PR #12115
  - SPU LLVM arm64+macOS — PR #12338 (mergée, nécessite un fork patché
    d'asmjit, `RPCS3/asmjit#1`, pour compiler)
  - Suivi de bugfixes : PR #12365 "arm64/macOS: fix some bugs"
  - Il existait déjà un portage Linux aarch64 "PPU only" antérieur (PR #11315)
- **Point critique** : ASMJIT (le recompileur SPU "rapide", handwritten en
  assembleur x86/SSE/AVX) est x86-only. Le chemin arm64 utilise le
  recompileur **LLVM**, historiquement le chemin "lent" de RPCS3. Il n'existe
  aucun portage de l'ASMJIT SPU recompiler vers arm64 à ce jour. → Sur iPhone,
  on hérite du chemin le moins optimisé de tout RPCS3, sur un CPU (Cell BE)
  qui est déjà à la limite du jouable sur des PC modernes pour beaucoup de
  jeux.
- RSX (le GPU du PS3) : pas de renderer Metal natif. RPCS3 tourne en Vulkan,
  traduit vers Metal via **MoltenVK** sur macOS/Apple Silicon. Confirmé par
  la communauté RPCS3 elle-même : "No one wanted a Native metal version.
  MoltenVK is doing perfectly fine" (macOS desktop). Personne n'a testé
  MoltenVK-sur-iOS avec une charge RSX/PS3. Aucune donnée de perf disponible.
- Connu et documenté : compilation des shaders lente/stutter, RPCS3 peut
  consommer 5+ Go de RAM rien que pour le cache de shaders sur certains jeux
  desktop. Sur iPhone (mémoire partagée, jetsam agressif), c'est un risque
  direct de kill par l'OS.

## 3. Le vrai précédent technique : ARMSX2 (et notre propre AYS2)

AYS2 (notre projet PS2) n'est **pas** un portage écrit from-scratch : c'est un
reskin de **ARMSX2** (`github.com/ARMSX2/ARMSX2`), un fork indépendant de
PCSX2 qui réécrit les recompileurs JIT x86-only de PCSX2 (EE, IOP, VU0, VU1,
vtlb fastmem) en natif ARM64, avec un frontend SwiftUI iOS déjà fonctionnel.
Le vrai travail d'ingénierie (recompileur ARM64, contournement JIT iOS,
Metal, bridge Swift/C++) a été fait une fois par l'équipe ARMSX2 ; AYS2 (et
d'autres, `iPSX2`, etc.) ne font que le rebrander.

**Il n'existe pas d'équivalent "ARMSX3" pour RPCS3.** Si on veut un
émulateur PS3 iOS, on doit être la première équipe à faire, pour Cell BE +
RSX, ce qu'ARMSX2 a fait pour Emotion Engine + GS — sauf que Cell BE (1 PPU +
jusqu'à 6 SPU actifs, DMA local-store, ordonnancement temps réel strict) est
d'un ordre de grandeur plus complexe que l'EE du PS2, et RSX est un GPU
propriétaire nVidia bien plus proche d'un GPU PC moderne que le GS du PS2.
RPCS3 lui-même a mis **une décennie** à atteindre son niveau de compatibilité
actuel sur desktop, avec une équipe dédiée.
(<https://dev.to/fares_haroun_843cfa2d784e/how-rpcs3-emulates-the-ps3-and-why-it-took-a-decade-of-unreasonable-effort-17kk>)

## 4. Le contournement JIT iOS : StikDebug + le hack "dual-map / TXM"

- **StikDebug** (`github.com/StephenDev0/StikDebug`) : JIT enabler on-device
  pour iOS 17.4+, basé sur `idevice`. Attache un faux debugserver au
  processus sideloadé (qui a l'entitlement `get-task-allow`) pour poser le
  flag `CS_DEBUGGED`, sans PC après le pairing initial.
- Il embarque un dossier `Scripts/` avec des automations JS
  (`geode.js`, `UTM-Dolphin.js`, `maciOS.js`, `manic.js`, `universal.js`) qui
  ré-attachent automatiquement le debugger à chaque relance de l'app — le
  flag `CS_DEBUGGED` ne survit pas à un relaunch. **`UTM-Dolphin.js` /
  `universal.js` sont déjà utilisés tels quels pour XeniOS et pour
  ARMSX2/AYS2** : ce n'est pas à réinventer, juste à réutiliser.
- **iOS 26 a cassé le vieux mécanisme simple** ("CS_DEBUGGED suffit pour
  `mmap(MAP_JIT)`"). Sur puces A15/M2+ (présence de TXM, Trusted Execution
  Monitor, détectée en sondant
  `/System/Volumes/Preboot/*/boot/*/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4`),
  il faut désormais un aller-retour bas niveau avec le debugger attaché : une
  instruction `brk #0xf00d` (avec `x16` comme "commande", `x0`/`x1` comme
  adresse/taille) que StikDebug intercepte côté debugger pour autoriser la
  région mémoire — cf. l'implémentation déjà écrite et **prouvée
  fonctionnelle sur device (iPhone 15, iOS 26.3)** dans notre propre
  `AYS2/src/cpp/common/Darwin/DarwinMisc.cpp` (`JitMode::LuckTXM` /
  `LuckNoTXM`, fonctions `JIT26PrepareRegion`/`JIT26Detach`,
  `MmapCodeDualMap`).
- **Nom révélateur** : les auteurs eux-mêmes appellent ces modes "Luck-TXM" /
  "Luck-No-TXM". C'est un hack opportuniste reverse-engineé par la
  communauté, pas une API stable. Il a déjà changé une fois avec iOS 26 ; il
  peut recasser à tout moment avec une future version iOS. À traiter comme
  une **dépendance externe fragile**, pas une fondation.
- Précédent supplémentaire : **DolphiniOS** (GameCube/Wii, OatmealDome) a
  défriché la même problématique dès 2020 (entitlement `dynamic-codesigning`
  interdit aux apps tierces, JIT W^X via `ptrace`/debugserver,
  `CS_DEBUGGED`), et possède un vrai renderer **Metal natif** (par
  TellowKrinkle) — contrairement à RPCS3 qui n'a que Vulkan/MoltenVK. C'est
  la référence la plus proche d'un "gros" JIT-emulator iOS mature, à étudier
  pour la partie rendu si on veut un jour dépasser MoltenVK.

## 5. Sources principales

- RPCS3 arm64 : <https://blog.rpcs3.net/2024/12/09/introducing-rpcs3-for-arm64/>
- PR PPU arm64 : <https://github.com/RPCS3/rpcs3/pull/12115>
- PR SPU arm64 : <https://github.com/RPCS3/rpcs3/pull/12338>
- RPCS3 refuse mobile : <https://www.notebookcheck.net/RPCS3-team-shares-why-the-PS3-emulator-won-t-land-on-Android-and-iOS-anytime-soon.930245.0.html>
- Avertissement anti-scam RPCS3 : <https://www.timeextension.com/news/2024/09/rpcs3-issues-warning-about-ps3-scam-emulators-for-mobile>
- ARMSX2 : <https://github.com/ARMSX2/ARMSX2>
- StikDebug : <https://github.com/StephenDev0/StikDebug>
- DolphiniOS : <https://github.com/OatmealDome/dolphin-ios>, <https://dolphinios.oatmealdome.me/jit-help>
- XeniOS (précédent Xbox 360) : <https://github.com/xenios-jp/XeniOS>
- Architecture RPCS3 (vulgarisation) : <https://dev.to/fares_haroun_843cfa2d784e/how-rpcs3-emulates-the-ps3-and-why-it-took-a-decade-of-unreasonable-effort-17kk>
- Notre code JIT déjà fonctionnel (à réutiliser) : `AYS2/src/cpp/common/Darwin/DarwinMisc.cpp`,
  `AYS2/src/cpp/Entitlements.plist`, `AYS2/docs/ARMSX2_MIGRATION.md`
