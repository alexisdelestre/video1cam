# Video1Cam

Video1Cam enregistre votre écran sur Mac, avec votre caméra et votre voix, à la manière de Loom. C'est utile pour une démo, un tutoriel, une passation ou un retour sur un projet.

Il n'y a ni compte ni abonnement, et rien ne part sur Internet. Les vidéos restent sur votre Mac, au format MP4, lisible partout.

**[⬇︎ Télécharger la dernière version](../../releases/latest)** · macOS 15 (Sequoia) ou plus récent · Mac Intel et Apple Silicon

---

## Fonctionnalités

- **Choix de ce qui est filmé** : tout l'écran, une zone dessinée à la souris, ou une fenêtre (un clic dessus suffit).
- **Bulle caméra** : votre visage dans une bulle ronde, que vous déplacez où vous voulez. Clic droit dessus pour changer sa taille.
- **Son** : votre micro et le son du Mac (une vidéo, une alerte…), réunis sur une même piste.
- **Souris** : le curseur est visible et les clics sont mis en évidence.
- **Pendant l'enregistrement** :
  - pause et reprise ;
  - compte à rebours de 3 secondes ;
  - indicateur de niveau du micro ;
  - raccourcis clavier utilisables depuis n'importe quelle application.
- **Commandes invisibles** : la barre de contrôle et les fenêtres de Video1Cam n'apparaissent jamais dans la vidéo.
- **Fichiers bien rangés** : chaque vidéo est nommée par la date et le titre, par exemple `2026-09-30_15-42_demo-nouvelle-interface.mp4`.
- **Rien n'est perdu** : si le Mac ou l'application plante pendant l'enregistrement, la vidéo est proposée au prochain lancement.

## Installation

1. Téléchargez **`Video1Cam-x.y.z.zip`** depuis la [page des versions](../../releases/latest), puis double-cliquez dessus pour le décompresser.
2. Glissez **Video1Cam** dans votre dossier **Applications**.
3. Ouvrez-la. Comme l'application n'est pas distribuée par l'App Store, macOS la bloque la première fois :
   - fermez le message d'avertissement ;
   - ouvrez **Réglages Système › Confidentialité et sécurité** ;
   - descendez jusqu'au message concernant Video1Cam et cliquez sur **Ouvrir quand même**.

   Cette étape n'est nécessaire qu'une seule fois.

<details>
<summary>Alternative avec le Terminal</summary>

```bash
xattr -dr com.apple.quarantine /Applications/Video1Cam.app
```
</details>

### Autorisations

Au premier usage, macOS demande trois autorisations :

| Autorisation | Pourquoi |
|---|---|
| **Enregistrement de l'écran et de l'audio système** | filmer l'écran et capter le son du Mac |
| **Caméra** | afficher la bulle caméra |
| **Microphone** | enregistrer votre voix |

Pour l'écran, macOS vous envoie dans les Réglages. Activez **Video1Cam**, puis **quittez et rouvrez l'application** : macOS l'exige.

## Utilisation

1. Dans la fenêtre de Video1Cam, choisissez **Plein écran** ou **Zone / fenêtre**.
2. Activez ou désactivez la caméra, le micro et le son du Mac.
3. Cliquez sur **Enregistrer**. Un compte à rebours de 3 secondes démarre ; appuyez sur Échap pour annuler.
4. Une barre de contrôle apparaît en bas de l'écran. Elle permet de mettre en pause, de terminer ou d'annuler.
5. Une fois l'enregistrement terminé, donnez un titre à la vidéo. Vous pouvez ensuite la lire, l'afficher dans le Finder ou copier son chemin.

### Raccourcis clavier

Ils fonctionnent même quand une autre application est au premier plan.

| Raccourci | Action |
|---|---|
| `⌥ ⇧ ⌘ R` | démarrer / terminer l'enregistrement |
| `⌥ ⇧ ⌘ P` | pause / reprise |
| `Échap` | annuler le compte à rebours ou la sélection de zone |

L'icône ⏺ dans la barre des menus donne aussi accès à ces commandes, et affiche la durée en cours.

### Où sont mes vidéos ?

Par défaut, elles sont dans **Vidéos › Video1Cam**. Vous pouvez choisir un autre dossier dans la fenêtre principale, y compris un dossier partagé ou synchronisé (Google Drive, Dropbox, iCloud…).

## Qualité et taille des fichiers

| Qualité | Taille maximale approximative |
|---|---|
| 1080p (par défaut) | ~30 Mo par minute |
| 1440p | ~60 Mo par minute |
| 4K | ~130 Mo par minute |

Ce sont des maximums : un écran qui bouge peu donne des fichiers bien plus légers.

Le format **HEVC** réduit la taille d'environ un tiers, mais certains navigateurs ne le lisent pas. Restez en **H.264** si vous partagez vos vidéos sur le web.

## Questions fréquentes

**La bulle caméra apparaît-elle dans la vidéo ?**
Oui, c'est voulu. Elle est filmée là où vous la placez. En mode zone, elle est automatiquement ramenée dans la zone filmée si elle en sort.

**Je veux filmer une fenêtre. Si je la déplace, est-ce que l'enregistrement la suit ?**
Non. Video1Cam enregistre l'emplacement de la fenêtre au moment où vous cliquez dessus.

**macOS me redemande les autorisations après une mise à jour.**
C'est normal pour une application distribuée hors App Store. Réactivez Video1Cam dans **Réglages Système › Confidentialité et sécurité**, puis relancez-la.

**Pourquoi macOS me demande-t-il régulièrement de confirmer l'enregistrement de l'écran ?**
C'est une mesure de sécurité de macOS Sequoia. Elle s'applique à toutes les applications d'enregistrement d'écran.

**Mes vidéos sont-elles envoyées quelque part ?**
Non. Video1Cam fonctionne entièrement hors ligne.

## Compiler depuis les sources

Il faut les *Command Line Tools* d'Apple (`xcode-select --install`). Xcode n'est pas nécessaire.

```bash
./build.sh --install
```

Cette commande compile l'application (Intel et Apple Silicon) et l'installe dans `/Applications`. Les autres commandes utiles :

- `./build.sh --test` lance d'abord les tests du moteur d'enregistrement ;
- `./scripts/package.sh` produit le fichier `dist/Video1Cam-x.y.z.zip` à publier.

**Publier une version** : poussez une étiquette, par exemple `git tag v1.0.0 && git push --tags`. GitHub Actions compile l'application et crée la version avec le zip téléchargeable.

```
Sources/RecorderCore/   moteur : écriture vidéo, pause, synchro audio, conversion MP4
Sources/Video1Cam/      application : capture d'écran, bulle caméra, sélection de zone, interface
Sources/CoreTests/      tests du moteur (synchro image/son, pauses, reprise après crash)
```
