# Contribuer à Video1Cam

Ce guide s'adresse aux personnes qui veulent compiler l'application à partir du code, la modifier ou publier une nouvelle version. Pour simplement utiliser Video1Cam, téléchargez la [dernière version](../../releases/latest) : rien de ce qui suit n'est nécessaire.

## Prérequis

- macOS 15 (Sequoia) ou plus récent
- Les *Command Line Tools* d'Apple, qui contiennent le compilateur Swift. Xcode n'est pas nécessaire.

  ```bash
  xcode-select --install
  ```

## Compiler et installer

```bash
./build.sh --install
```

Cette commande :

1. compile l'application pour Mac Intel et Apple Silicon ;
2. lui ajoute son icône et la signe ;
3. la copie dans `/Applications`.

Sans `--install`, l'application est seulement créée dans `build/Video1Cam.app`.

## Lancer les tests

```bash
./build.sh --test
```

Les tests s'exécutent avant la compilation. S'ils échouent, rien n'est construit.

Ils simulent un enregistrement complet avec :

- deux pistes audio de formats différents ;
- des coupures de son et un écran immobile ;
- une pause et un crash.

Ils vérifient ensuite le MP4 produit : durée exacte, son synchronisé avec l'image (à quelques millisecondes près) et récupération de la vidéo après un crash.

Pour lancer uniquement les tests :

```bash
swift build -c release --product CoreTests && .build/release/CoreTests
```

## Organisation du code

```
Sources/RecorderCore/   moteur : écriture vidéo, pause, synchro audio, conversion MP4
Sources/Video1Cam/      application : capture d'écran, bulle caméra, sélection de zone, interface
Sources/CoreTests/      tests du moteur
Resources/Info.plist    nom, version et textes des demandes d'autorisation
scripts/                icône et création du zip de distribution
```

## Publier une nouvelle version

1. Mettez à jour le numéro de version (`CFBundleShortVersionString`) dans `Resources/Info.plist`, par exemple `1.1.0`.
2. Committez ce changement.
3. Posez l'étiquette correspondante et envoyez-la sur GitHub :

   ```bash
   git tag v1.1.0 && git push --tags
   ```

GitHub Actions compile alors l'application, lance les tests et crée la version avec le fichier `Video1Cam-1.1.0.zip` à télécharger. Vous pouvez suivre le déroulement dans l'onglet **Actions** du dépôt.

Pour produire le zip sur votre Mac sans passer par GitHub :

```bash
./scripts/package.sh
```

Le fichier est créé dans `dist/`.

## Signature

L'application est signée « ad hoc », sans compte Apple Developer. macOS la bloque donc au premier lancement, et le README explique comment l'ouvrir quand même. macOS peut aussi redemander les autorisations (écran, caméra, micro) après chaque nouvelle version.
