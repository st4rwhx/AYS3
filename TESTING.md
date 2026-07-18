# AYS3 — Stratégie de test différentiel / automatisation

Complément à `PLAN.md`. Répond à un problème concret : le cycle manuel
(build → câble → StikDebug → observer l'écran d'un iPhone) ne scale pas sur
la durée du projet. Ce document définit ce qu'on automatise, comment, et où
sont les limites — pas de survente.

## Principe

On ne cherche pas à construire une VM iOS fidèle au silicium (Secure
Enclave / TXM inclus) — ça n'existe pas en dehors de produits commerciaux
type Corellium, et rien ne garantit qu'une virtualisation reproduise
fidèlement un mécanisme pensé pour être non-falsifiable par un environnement
virtuel. On construit à la place un **harnais de test différentiel** :
comparer automatiquement le comportement de notre fork à une référence
connue-correcte, et localiser automatiquement le premier point de
divergence. C'est la méthode que RPCS3, Dolphin et la plupart des projets
d'émulation sérieux utilisent pour chasser les bugs de recompileur — pas le
jeu manuel.

## Le levier principal : macOS Apple Silicon comme banc d'essai gratuit

RPCS3 supporte déjà nativement l'arm64 macOS (PR #12115/#12338, voir
`RESEARCH.md`), en JIT natif standard (`mmap(MAP_JIT)`), **sans aucun hack
StikDebug/TXM**. macOS arm64 et iOS arm64 partagent le même jeu
d'instructions. Conséquence directe : tout le cœur PPU/SPU/RSX du fork peut
être développé et validé sur Mac, en JIT natif, avant de jamais toucher un
iPhone. Le device physique ne sert qu'au dernier kilomètre : fiabilité du
contournement JIT lui-même, tactile, perf/thermique réelles.

## Architecture du harnais

```
┌─────────────────────────┐        ┌─────────────────────────┐
│ RPCS3 desktop (référence)│        │  Fork AYS3 (candidat)    │
│  x86 ou arm64 macOS,      │        │  arm64 macOS d'abord,     │
│  connu-correct            │        │  iOS ensuite              │
│  + instrumentation trace  │        │  + même instrumentation   │
└────────────┬─────────────┘        └────────────┬─────────────┘
             │ trace.jsonl                          │ trace.jsonl
             └───────────────┬──────────────────────┘
                              ▼
                    tools/testharness/tracediff.py
                    → premier point de divergence
                      (seq, pc/spu_id, hash attendu vs obtenu)
```

### Format de trace (`trace.jsonl`, une ligne JSON par point de contrôle)

```json
{"seq": 48213, "kind": "ppu_block", "pc": "0x1002a4f0", "regs_hash": "sha256:...", "instr_count": 128}
{"seq": 48214, "kind": "spu_block", "spu_id": 2, "pc": "0x0003a0", "regs_hash": "sha256:...", "instr_count": 64}
{"seq": 48215, "kind": "frame", "frame_index": 900, "frame_hash": "sha256:..."}
```

- `regs_hash` : hash des registres généraux + flags pertinents à la fin du
  bloc (pas la mémoire complète — trop lourd, à affiner en Phase 1 selon ce
  qui est réellement observable/stable entre les deux implémentations).
- Cadence de checkpoint volontairement configurable (tous les N blocs CPU,
  tous les vblank pour le GPU) — un checkpoint par instruction serait
  hors de prix en volume de données et en overhead d'instrumentation.
- `frame_hash` : hash du framebuffer au moment du flip, pour détecter les
  divergences RSX indépendamment des divergences CPU.

### Outil de diff — `tools/testharness/tracediff.py`

Scaffoldé aujourd'hui, fonctionnel dès maintenant sur des traces
synthétiques (voir `tools/testharness/tests/`). Compare deux fichiers
`trace.jsonl` séquence par séquence, s'arrête au premier désaccord et
affiche le contexte (N enregistrements avant/après) au lieu de forcer un
diff manuel de logs bruts. Zéro dépendance externe (stdlib Python
uniquement) — utilisable direct en CI sans installation.

### CI — `.github/workflows/test-harness.yml`

Runner **macOS arm64 natif** (GitHub Actions `macos-14`/`macos-15`, gratuit
en runners hébergés, pas de matériel à nous). Pour l'instant le job ne fait
tourner que les tests du diff tool lui-même (aucune trace réelle tant que
le cœur RPCS3 n'est pas vendored — Phase 1 du plan). Les étapes futures sont
déjà posées en commentaires dans le workflow pour éviter de le réécrire de
zéro : build référence (RPCS3 desktop, instrumenté), build candidat (fork
arm64 macOS, instrumenté), exécution sur un corpus de homebrews, diff, échec
CI si divergence.

## Corpus de test (à constituer en Phase 1-2, pas encore fait)

Légal uniquement : homebrews PS3 open-source (SDK **PSL1GHT**, démos
publiques de la scène homebrew PS3), jamais de jeux commerciaux dans le
dépôt ni en CI. Objectif : quelques dizaines de binaires homebrew simples
couvrant progressivement PPU seul → PPU+SPU → PPU+SPU+RSX, avant de passer
à de vrais jeux (testés uniquement en local par l'utilisateur, sur ses
propres dumps, jamais en CI publique).

## Dernier kilomètre : device physique (non automatisable entièrement)

StikDebug est open-source et repose sur `idevice` — le flow d'attache JIT
n'exige pas son interface graphique, il est scriptable en ligne de commande.
Un petit banc auto-hébergé (Mac mini + 1-2 iPhones) peut donc : build →
déployer → déclencher le JIT → lancer un test → remonter logs/screenshots,
sans supervision humaine à chaque cycle. Ce que ça ne remplace pas : la
validation que le hack dual-map/TXM fonctionne réellement sur silicium à
chaque nouvelle version iOS — ça reste un test sur matériel réel,
irréductible.

## Ce que ce harnais NE fait PAS

- Il ne devine pas le comportement correct du RSX ou du firmware à notre
  place — il faut toujours écrire l'émulation.
- Il ne supprime pas le besoin de device réel pour la partie
  spécifiquement iOS (JIT bypass, tactile, thermique).
- Il transforme "des mois de debug par essai-erreur manuel" en "des heures
  de bisection automatique par bug" — un multiplicateur de vitesse
  d'itération, pas un remplacement du travail d'ingénierie de `PLAN.md`.

## Statut actuel

- [x] Format de trace défini.
- [x] `tracediff.py` scaffoldé et testé sur données synthétiques.
- [x] Squelette CI macOS arm64 posé.
- [ ] Bloqué sur Phase 1 (`PLAN.md`) : vendoring du fork RPCS3, instrumentation
      réelle référence + candidat, premier corpus homebrew.
