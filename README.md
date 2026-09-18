# nanocraft-zig

nanocraft-zig est un port optimisé de nanocraft-py (https://github.com/miiforlong/nanocraft-py) codé en zig 0.14.1



## Documentation pour la compilation (en utilisant MSYS2)

Ceci décrit l'environnement utilisé pour compiler NanoCraft en Zig sous Windows avec MSYS2 UCRT64.

### 1. Prérequis

Installer :

- **MSYS2**
- **Zig 0.14.1**
- **Raylib**
- **GLFW**
- Le fichier source `nanocraft.zig`
- Le fichier `terrain.png`

> Cette procédure utilise **Zig 0.14.1**.

---

### 2. Ouvrir le bon terminal MSYS2

Il faut ouvrir :

**MSYS2 UCRT64**

et non :

- MSYS2 MSYS
- MSYS2 MINGW64
- MSYS2 CLANG64

Le terminal doit afficher quelque chose ressemblant à :

```text
Miiforlong@Miiforlong UCRT64 ~
$
```

Le `UCRT64` est important : NanoCraft utilise les bibliothèques installées dans cet environnement.

---

### 3. Mettre à jour MSYS2

Dans **MSYS2 UCRT64** :

```bash
pacman -Syu
```

Si MSYS2 demande de fermer le terminal, fermez-le.

Rouvrez ensuite **MSYS2 UCRT64** et exécutez à nouveau :

```bash
pacman -Syu
```

---

### 4. Installer Raylib

Installer Raylib pour UCRT64 :

```bash
pacman -S mingw-w64-ucrt-x86_64-raylib
```

Vérifier que Raylib est bien installé :

```bash
ls /ucrt64/include/raylib.h
```

Puis :

```bash
ls /ucrt64/lib/*raylib*
```

On doit notamment retrouver :

```text
/ucrt64/lib/libraylib.a
/ucrt64/lib/libraylib.dll.a
```

---

### 5. Installer GLFW

Installer GLFW :

```bash
pacman -S mingw-w64-ucrt-x86_64-glfw
```

Vérifier :

```bash
ls /ucrt64/lib/*glfw*
```

On doit notamment retrouver :

```text
/ucrt64/lib/libglfw3.a
/ucrt64/lib/libglfw3.dll.a
```

---

### 6. Vérifier Zig 0.14.1

NanoCraft utilise **Zig 0.14.1**.

Le dossier doit contenir :

```text
zig-0.14.1/
└── zig.exe
```

Depuis le dossier du projet, vérifier la version :

```bash
zig-0.14.1/zig.exe version
```

Résultat attendu :

```text
0.14.1
```

> Si plusieurs versions de Zig sont installées, utiliser explicitement `zig-0.14.1/zig.exe`.

Ne pas utiliser simplement :

```bash
zig version
```

si cette commande pointe vers une autre version de Zig.

---

### 7. Aller dans le dossier du projet

Exemple :

```bash
cd /c/Users/%USERNAME%/Desktop/nanocraft-zig
```

Le terminal doit alors ressembler à :

```text
Miiforlong@Miiforlong UCRT64 /c/Users/%USERNAME%/Desktop/nanocraft-zig
$
```

Vérifier les fichiers :

```bash
ls
```

Le dossier doit notamment contenir :

```text
nanocraft.zig
terrain.png
zig-0.14.1/
```

---

### 8. Dépendances utilisées par NanoCraft

NanoCraft utilise :

- **Zig 0.14.1**
- **Raylib**
- **GLFW**
- **Windows Multimedia (`winmm`)**
- Le runtime C

Les headers sont recherchés dans :

```text
/ucrt64/include
```

Les bibliothèques sont recherchées dans :

```text
/ucrt64/lib
```

---

### 9. Commande de compilation

Depuis le dossier du projet :

```bash
zig-0.14.1/zig.exe build-exe nanocraft.zig -lc -I/ucrt64/include -L/ucrt64/lib -lraylib.dll -lglfw3.dll -lwinmm
```

Cette commande est la commande de référence pour compiler NanoCraft.

#### Explication

```text
zig-0.14.1/zig.exe
```

Utilise Zig 0.14.1.

```text
build-exe
```

Compile le programme en exécutable.

```text
nanocraft.zig
```

Fichier source principal.

```text
-lc
```

Lie le programme avec le runtime C.

```text
-I/ucrt64/include
```

Indique à Zig où trouver les headers C.

```text
-L/ucrt64/lib
```

Indique à Zig où chercher les bibliothèques.

```text
-lraylib.dll
```

Utilise l'import library de Raylib.

```text
-lglfw3.dll
```

Utilise l'import library de GLFW.

```text
-lwinmm
```

Lie avec la bibliothèque Windows Multimedia.

---

### 10. Pourquoi utiliser `-lraylib.dll` et `-lglfw3.dll` ?

Dans l'environnement UCRT64, Raylib fournit notamment :

```text
libraylib.a
libraylib.dll.a
```

GLFW fournit notamment :

```text
libglfw3.a
libglfw3.dll.a
```

Pour cette configuration de NanoCraft, on utilise :

```bash
-lraylib.dll -lglfw3.dll
```

La commande complète reste donc :

```bash
zig-0.14.1/zig.exe build-exe nanocraft.zig -lc -I/ucrt64/include -L/ucrt64/lib -lraylib.dll -lglfw3.dll -lwinmm
```

---

### 11. Résultat de la compilation

Si la compilation réussit, Zig produit :

```text
nanocraft.exe
```

Vérifier :

```bash
ls -l nanocraft.exe
```

---

### 12. Vérifier les DLL nécessaires

La compilation peut réussir alors que Windows ne trouve pas les DLL nécessaires au lancement.

Chercher Raylib :

```bash
find /ucrt64 -iname "*raylib*.dll"
```

Chercher GLFW :

```bash
find /ucrt64 -iname "*glfw*.dll"
```

Les DLL nécessaires doivent être accessibles par Windows lorsque :

```text
nanocraft.exe
```

est lancé.

Une solution simple est de placer les DLL nécessaires directement à côté de :

```text
nanocraft.exe
```

> Ne pas copier automatiquement tout le contenu de `/ucrt64/bin`. Seules les DLL nécessaires au programme doivent être rendues disponibles.

---

### 13. Lancer NanoCraft depuis MSYS2

Depuis le dossier du projet :

```bash
./nanocraft.exe
```

Le programme doit également pouvoir trouver :

```text
terrain.png
```

Il est donc recommandé de lancer le programme depuis le dossier contenant les ressources du jeu.

---

### 14. Lancer NanoCraft depuis PowerShell

Depuis PowerShell :

```powershell
cd C:\Users\%USERNAME%\Desktop\nanocraft-zig
```

Puis :

```powershell
.\nanocraft.exe
```

Les DLL nécessaires doivent également être accessibles à Windows.

---

### 15. Vérification complète de l'installation

#### Vérifier Zig

```bash
zig-0.14.1/zig.exe version
```

Résultat attendu :

```text
0.14.1
```

#### Vérifier Raylib

```bash
ls /ucrt64/include/raylib.h
```

#### Vérifier les bibliothèques Raylib

```bash
ls /ucrt64/lib/*raylib*
```

#### Vérifier les bibliothèques GLFW

```bash
ls /ucrt64/lib/*glfw*
```

#### Vérifier le fichier source

```bash
ls nanocraft.zig
```

#### Vérifier la texture

```bash
ls terrain.png
```

---

### 16. Procédure complète

Une fois MSYS2, Raylib, GLFW et Zig 0.14.1 installés :

```bash
cd /c/Users/%USERNAME%/Desktop/nanocraft-zig

zig-0.14.1/zig.exe version

ls /ucrt64/include/raylib.h

ls /ucrt64/lib/*raylib*

ls /ucrt64/lib/*glfw*

ls nanocraft.zig

ls terrain.png

zig-0.14.1/zig.exe build-exe nanocraft.zig -lc -I/ucrt64/include -L/ucrt64/lib -lraylib.dll -lglfw3.dll -lwinmm

./nanocraft.exe
```

---

### 17. Erreur `raylib.h: No such file or directory`

Si Zig affiche :

```text
raylib.h: No such file or directory
```

Vérifier :

```bash
ls /ucrt64/include/raylib.h
```

Si le fichier existe, vérifier que la commande de compilation contient :

```text
-I/ucrt64/include
```

Si Raylib n'est pas installé :

```bash
pacman -S mingw-w64-ucrt-x86_64-raylib
```

---

### 18. Erreur `cannot find -lraylib.dll`

Vérifier :

```bash
ls /ucrt64/lib/*raylib*
```

Puis :

```bash
ls /ucrt64/lib/libraylib.dll.a
```

Si Raylib n'est pas installé :

```bash
pacman -S mingw-w64-ucrt-x86_64-raylib
```

---

### 19. Erreur `cannot find -lglfw3.dll`

Vérifier :

```bash
ls /ucrt64/lib/*glfw*
```

Puis :

```bash
ls /ucrt64/lib/libglfw3.dll.a
```

Si GLFW n'est pas installé :

```bash
pacman -S mingw-w64-ucrt-x86_64-glfw
```

---

### 20. Erreur `libraylib.dll` au lancement

Si la compilation fonctionne mais que Windows affiche une erreur concernant :

```text
libraylib.dll
```

chercher la DLL :

```bash
find /ucrt64 -iname "*raylib*.dll"
```

Puis rendre cette DLL accessible à :

```text
nanocraft.exe
```

La solution la plus simple est généralement de placer la DLL à côté de l'exécutable.

---

### 21. Erreur `root source file struct 'nanocraft' has no member named 'main'`

Cette erreur :

```text
root source file struct 'nanocraft' has no member named 'main'
```

signifie que le fichier source ne contient pas de fonction principale :

```zig
pub fn main() !void {
    // ...
}
```

ou que le fichier `nanocraft.zig` est incomplet ou tronqué.

Ce problème n'est pas lié à Raylib ou à MSYS2.

---

### 22. Erreur `expected '}' found 'EOF'`

Une erreur comme :

```text
error: expected '}', found 'EOF'
```

signifie qu'une accolade fermante manque dans le fichier Zig.

Exemple :

```zig
const Example = struct {
    fn test() void {
        // ...
    }
};
```

Une structure doit être correctement fermée avec :

```zig
};
```

Si le fichier s'arrête brutalement au milieu du code, vérifier également que `nanocraft.zig` n'a pas été tronqué.

---

### 23. Structure finale de l'environnement

```text
Windows
│
└── MSYS2
    │
    └── UCRT64
        │
        ├── /ucrt64/include
        │   └── raylib.h
        │
        ├── /ucrt64/lib
        │   ├── libraylib.a
        │   ├── libraylib.dll.a
        │   ├── libglfw3.a
        │   └── libglfw3.dll.a
        │
        └── /ucrt64/bin
            └── DLL nécessaires
```

Projet :

```text
nanocraft-zig/
│
├── nanocraft.zig
├── terrain.png
├── zig-0.14.1/
│   └── zig.exe
└── nanocraft.exe
```

---

### 24. Commande de référence

La commande utilisée pour compiler cette version de NanoCraft est :

```bash
zig-0.14.1/zig.exe build-exe nanocraft.zig -lc -I/ucrt64/include -L/ucrt64/lib -lraylib.dll -lglfw3.dll -lwinmm
```

**Terminal requis : MSYS2 UCRT64**

**Version Zig : 0.14.1**

**Raylib : `mingw-w64-ucrt-x86_64-raylib`**

**GLFW : `mingw-w64-ucrt-x86_64-glfw`**
