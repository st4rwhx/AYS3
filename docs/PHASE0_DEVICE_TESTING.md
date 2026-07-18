# Phase 0 — test sur device réel

Ce que le code fait automatiquement (CI, voir `.github/workflows/build-ios.yml`)
s'arrête à "ça compile et ça produit un IPA non signé". Personne dans cette
chaîne d'outils ne peut vérifier que le contournement JIT marche réellement
sur du silicium — ça, seul un device physique le dit. Cette page est le
protocole pour le faire.

## Ce que tu dois avoir

- Un iPhone/iPad réel (pas le simulateur — le simulateur a un JIT natif de
  toute façon, il ne teste rien d'utile ici).
- [StikDebug](https://github.com/StephenDev0/StikDebug) installé (via
  AltStore/SideStore/Sideloadly).
- L'IPA `AYS3.ipa` produit par la CI (onglet Actions du repo → dernier run
  vert → artifact `AYS3-<sha>`), ou buildé toi-même en local via Xcode.

## Étapes

1. **Sideload AYS3.ipa** avec Sideloadly ou AltStore/SideStore, comme
   n'importe quelle app JIT (Dolphin, XeniOS, AYS2...).
2. **Pairing StikDebug** : si ce n'est pas déjà fait, génère/importe le
   fichier de pairing (`.mobiledevicepairing`/`.plist`) dans StikDebug —
   étape unique, à refaire seulement si le pairing expire.
3. **VPN loopback** : active le VPN local que StikDebug demande (nécessaire
   pour qu'il parle au démon `idevice` sur l'appareil).
4. **Lance AYS3** une première fois (elle va démarrer, mais `CS_DEBUGGED`
   sera à `no` tant que le JIT n'est pas activé — normal, c'est justement ce
   que l'app va te montrer).
5. Dans StikDebug, sélectionne **AYS3** dans la liste des apps
   (elle apparaît parce qu'elle a l'entitlement `get-task-allow`) et appuie
   sur le bouton **JIT**.
6. Reviens sur AYS3, relance-la si besoin, appuie sur **"Run JIT stub
   probe"**.

## Ce que tu dois voir

- `CS_DEBUGGED` : **yes** après l'étape 5. Si ça reste à `no`, StikDebug n'a
  pas réussi à s'attacher — revérifie le pairing/VPN avant d'aller plus
  loin.
- `JIT mode` : `LuckTXM` sur iPhone 13 (A15) ou plus récent avec iOS 26+,
  `Legacy` sur iOS 25 et antérieur, `LuckNoTXM` seulement si tu forces la
  variable d'env `AYS3_FORCE_DUAL_MAP=1`.
- `Stub result` : **PASS (returned 42)**. C'est le signal qu'on cherche —
  ça veut dire qu'on a écrit du code arm64 dans une page mémoire obtenue
  sans l'entitlement `dynamic-codesigning`, qu'on l'a rendue exécutable, et
  qu'elle a tourné. C'est *exactement* la fondation dont tout le reste du
  plan (`PLAN.md`) dépend.
- Si ça échoue, le **log d'étapes** affiché sous le bouton dit où : pas de
  CS_DEBUGGED, `brk #0xf00d` qui lève un vrai SIGTRAP (= pas de debugger
  réellement attaché malgré le bouton StikDebug), `vm_remap` qui échoue
  (= TXM bloque la double-map sur ce device/cette version iOS précise), etc.
  Rapporte ce log tel quel si tu ouvres une issue — c'est fait pour être
  copié-collé directement.

## Après un succès

Note la combinaison exacte iPhone / version iOS / mode JIT obtenu quelque
part (issue GitHub, ou juste garde le screenshot) — c'est la première
donnée réelle du registre de risques de `PLAN.md` (risque #1 : fragilité du
hack JIT face aux mises à jour iOS). Chaque test réussi sur un nouveau
device/version iOS réduit l'incertitude sur ce risque précis.

## Après un échec

Ce n'est pas la fin du plan — Phase 0 existe justement pour trouver ça
maintenant, avant d'avoir investi dans le portage RPCS3 (Phase 1+). Un échec
ici avec un log clair est une information utile ; ouvre une issue avec le
log complet, le modèle d'iPhone et la version iOS.
