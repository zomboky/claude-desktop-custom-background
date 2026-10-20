# Claude Desktop Custom Background

Affiche une image de fond, avec l'opacité de ton choix, sur **Claude Desktop**.

![Plateforme : Windows](https://img.shields.io/badge/plateforme-Windows%2010%20%7C%2011-0078D4)
![Dépendances : aucune](https://img.shields.io/badge/d%C3%A9pendances-aucune-brightgreen)

> **Windows uniquement pour le moment.** Le projet utilise l'API Win32 (fenêtres, événements, DWM) via PowerShell et .NET Framework, fournis avec Windows. Aucun équivalent macOS/Linux n'existe encore.

![Comparaison de plusieurs opacités](docs/opacity-comparison.png)

*Illustrations générées : maquette de l'interface avec l'image d'exemple fournie dans [`assets/`](assets/), pas de vraies captures d'écran. Seule la valeur `opacity` change d'une image à l'autre.*

## Sommaire

- [Pourquoi un calque et pas du CSS ?](#pourquoi-un-calque-et-pas-du-css-)
- [Installation](#installation)
- [Configuration](#configuration)
- [Lancement avec Claude Desktop](#lancement-avec-claude-desktop)
- [Fonctionnement](#fonctionnement)
- [Limites](#limites)
- [Dépannage](#dépannage)
- [Désinstallation](#désinstallation)

## Pourquoi un calque et pas du CSS ?

Claude Desktop est une application Electron : on pourrait imaginer y injecter du CSS. Mais :

- l'application est installée en MSIX dans `C:\Program Files\WindowsApps\`, un dossier en lecture seule qui se met à jour tout seul, donc on ne peut pas la patcher proprement ;
- elle **refuse volontairement de démarrer** avec un port de debug (`--remote-debugging-port`) : `Claude: refusing to start — a debugging or network-override switch is present on the command line.`

Ce projet ne contourne donc rien : il ne touche pas à Claude. Il affiche **une fenêtre séparée**, transparente aux clics, posée au-dessus de la fenêtre de Claude.

## Installation

### Prérequis

- Windows 10 ou 11
- Windows PowerShell 5.1 (déjà présent sur Windows, rien à installer)
- Claude Desktop

Testé sur Windows 11.

### Étapes

1. **Récupère le projet** : `git clone https://github.com/zomboky/claude-desktop-custom-background.git`, ou télécharge le ZIP depuis GitHub et décompresse-le. Place le dossier à un endroit stable : le lancement automatique en dépend.

2. **Choisis ton image** : dépose-la où tu veux (JPG, PNG, BMP, GIF ou TIFF ; le WebP n'est pas géré par .NET Framework). Pour tester sans rien faire, l'image d'exemple [`assets/sample-background.jpg`](assets/sample-background.jpg) est utilisée par défaut.

3. **Lance l'installation** dans PowerShell, depuis le dossier du projet :

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

   Le script :
   - crée `config.json` à partir de [`config.example.json`](config.example.json) s'il n'existe pas ;
   - crée un raccourci dans ton dossier Démarrage (voir [Lancement avec Claude Desktop](#lancement-avec-claude-desktop)) ;
   - démarre le calque tout de suite.

4. **Ouvre Claude Desktop** : l'image apparaît. Pas de droits administrateur nécessaires.

5. **Mets ton image** : édite `config.json` (voir ci-dessous). Le changement est pris en compte en une seconde environ, sans redémarrer.

Pour un lancement ponctuel, sans installer le démarrage automatique :

```powershell
powershell -ExecutionPolicy Bypass -File .\overlay.ps1
```

(la fenêtre PowerShell doit rester ouverte, ou utilise `wscript.exe start-hidden.vbs` pour un lancement sans fenêtre).

## Configuration

Tout passe par `config.json`, relu en direct pendant que le calque tourne. `config.json` est ignoré par git : tes chemins personnels ne seront pas publiés.

```json
{
  "image": "C:/Users/toi/Pictures/mon-fond.png",
  "opacity": 0.15,
  "fit": "cover"
}
```

| Clé | Valeur | Rôle |
| --- | --- | --- |
| `image` | chemin | Image à afficher. Absolu, ou relatif au dossier de `config.json`. |
| `opacity` | `0.01` à `0.99` (défaut `0.15`) | Opacité du calque. Plus c'est haut, plus l'image masque l'interface. |
| `fit` | `"cover"` (défaut) ou `"stretch"` | `cover` remplit la fenêtre en recadrant sans déformer ; `stretch` étire l'image aux dimensions de la fenêtre. |

> **Attention aux chemins Windows dans le JSON.** Les `\` doivent être doublés (`C:\\Users\\toi\\...`) ou remplacés par des `/` (`C:/Users/toi/...`). Un fichier invalide est ignoré : l'ancienne image reste affichée.

Le calque est dessiné **par-dessus** l'interface (voir [Fonctionnement](#fonctionnement)) : garde une opacité basse, entre `0.05` et `0.2`, pour que le texte reste lisible.

## Lancement avec Claude Desktop

`install.ps1` ajoute le raccourci `Claude overlay.lnk` dans le dossier Démarrage de Windows (`shell:startup`). À chaque ouverture de session :

1. `start-hidden.vbs` lance `overlay.ps1` sans aucune fenêtre visible ;
2. le calque attend en tâche de fond, invisible, sans rien afficher tant que Claude Desktop n'est pas ouvert ;
3. dès qu'une fenêtre de Claude apparaît, il la recouvre. Quand tu réduis ou fermes Claude, il se masque ;
4. un verrou interne (mutex) empêche de lancer deux instances.

Résultat : il se comporte comme s'il démarrait avec Claude Desktop, sans que tu aies à y penser. Le processus reste actif en permanence (environ 140 Mo de RAM) ; pour l'arrêter, clic droit sur son icône de la zone de notification, puis **Quitter**.

Pour le relancer à la main :

```powershell
wscript.exe .\start-hidden.vbs
```

## Fonctionnement

![Schéma des couches](docs/how-it-works.png)

Tout est dans [`overlay.ps1`](overlay.ps1) : un petit programme C# compilé à la volée par PowerShell (`Add-Type`), sans rien à installer.

- **Une fenêtre séparée.** Le calque est un formulaire WinForms sans bordure avec les styles étendus `WS_EX_TRANSPARENT` (les clics passent au travers), `WS_EX_NOACTIVATE` (il ne prend jamais le focus) et `WS_EX_TOOLWINDOW` (pas d'entrée dans la barre des tâches ni dans Alt+Tab). L'opacité est celle de la fenêtre elle-même (`Form.Opacity`).
- **Il retrouve Claude.** Il énumère les fenêtres de premier niveau de classe `Chrome_WidgetWin_1` appartenant à un processus `claude`, et garde la plus grande.
- **Il suit Claude par événements.** Avec `SetWinEventHook`, Windows le prévient à chaque déplacement ou redimensionnement de la fenêtre (`EVENT_OBJECT_LOCATIONCHANGE`), au changement de premier plan, à la minimisation et à l'affichage/masquage. Pas de boucle de surveillance rapide : un minuteur de 250 ms ne sert que de filet de sécurité (ouverture de Claude, ordre des fenêtres).
- **Dimensions exactes.** Il lit la zone visible via `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`, qui exclut les marges invisibles de Windows 10/11, et se déclare compatible per-monitor DPI v2 pour avoir de vrais pixels sur les écrans à mise à l'échelle.
- **Ordre Z.** Il se place **juste au-dessus de Claude** (`SetWindowPos` avec la fenêtre qui précède Claude), et non en « toujours au premier plan » : les autres fenêtres passent devant, comme elles le feraient devant Claude.
- **Image rapide.** L'image est décodée une fois, réduite à la taille du plus grand écran et convertie en `Format32bppPArgb` (le format le plus rapide à dessiner). Une copie recadrée à la taille exacte de la fenêtre est mise en cache : déplacer la fenêtre ne redessine rien, la redimensionner ne refait que cette copie.
- **Coins arrondis.** `DWMWA_WINDOW_CORNER_PREFERENCE` est réglé sur arrondi (Windows 11) pour épouser la fenêtre.
- **Config en direct.** `config.json` est surveillé (date de modification) et rechargé sans redémarrage.

## Limites

- **Windows uniquement.** Aucun support macOS ou Linux pour l'instant.
- **Le calque est au-dessus de l'interface**, pas derrière : les fonds de Claude sont opaques, un calque placé derrière serait invisible. L'image se superpose donc au texte, d'où l'opacité basse conseillée.
- **Le suivi n'est pas parfaitement synchrone** : c'est une fenêtre séparée qui suit Claude. Un léger décalage est possible pendant un déplacement très rapide.
- Le calque suit **une seule fenêtre Claude** : la plus grande visible.
- Ce n'est pas une fonction de Claude Desktop : une mise à jour majeure de l'application qui changerait le type de ses fenêtres pourrait nécessiter d'adapter la détection (`IsClaudeWindow` dans `overlay.ps1`).
- L'opacité est uniforme sur toute l'image, il n'y a pas de dégradé.

## Dépannage

**L'image n'apparaît pas.**
- Vérifie que le calque tourne : `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'overlay.ps1' }`.
- Vérifie que `config.json` est du JSON valide (chemins avec `/` ou `\\`) et que l'image existe.
- Pour voir les messages, lance `overlay.ps1` dans une fenêtre PowerShell visible : `config: opacity=… image=…` confirme le chargement, `config: …` suivi d'une erreur en indique la cause.

**Le calque ne se lance pas à l'ouverture de session.** Vérifie que `Claude overlay.lnk` est dans `shell:startup` et que le dossier du projet n'a pas été déplacé : relance `install.ps1` depuis le nouvel emplacement.

## Désinstallation

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Le script arrête le calque et supprime le raccourci de démarrage. Aucun fichier de Claude Desktop n'ayant été modifié, il n'y a rien d'autre à restaurer. Tu peux ensuite supprimer le dossier du projet.

## Contenu du dépôt

| Fichier | Rôle |
| --- | --- |
| `overlay.ps1` | Le calque (PowerShell + C# inline). |
| `start-hidden.vbs` | Lance `overlay.ps1` sans fenêtre. |
| `install.ps1` / `uninstall.ps1` | Ajoute / retire le lancement automatique. |
| `config.example.json` | Modèle de configuration. |
| `assets/sample-background.jpg` | Image d'exemple générée pour ce projet. |
| `docs/` | Illustrations du README. |
