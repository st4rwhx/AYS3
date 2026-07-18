# AYS3
PS3 emulator on iOS

Statut : **Phase 0** (voir `PLAN.md`) — squelette d'app iOS + preuve du
contournement JIT, pas encore de cœur RPCS3. Non testé sur device.

- [`RESEARCH.md`](RESEARCH.md) — état de l'art (RPCS3, ARMSX2, StikDebug, JIT iOS), sourcé.
- [`PLAN.md`](PLAN.md) — plan d'ingénierie phasé, critique, avec registre de risques.
- [`TESTING.md`](TESTING.md) — stratégie de test différentiel / automatisation.
- [`docs/PHASE0_DEVICE_TESTING.md`](docs/PHASE0_DEVICE_TESTING.md) — protocole de test sur iPhone réel (StikDebug).

Aucun firmware, BIOS ou ISO n'est ni ne sera jamais distribué dans ce repo :
dumpe tes propres fichiers depuis ton propre PS3.

Licence : GPL-3.0 (voir `LICENSE`, `NOTICE`) — le contournement JIT est
adapté du projet AYS2 de ce compte, lui-même dans la lignée ARMSX2/PCSX2.
