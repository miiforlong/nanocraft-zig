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

Il faut ouvrir **MSYS2 UCRT64**

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

NanoCraft utilise **Zig 0.14.1** (trouvable sur <https://ziglang.org/download/>) .


Depuis le dossier du projet, vérifier la version :

```bash
zig version
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
zig build-exe nanocraft.zig -lc -I/ucrt64/include -L/ucrt64/lib -lraylib.dll -lglfw3.dll -lwinmm
```

Cette commande est la commande de référence pour compiler NanoCraft.

#### Explication

```text
zig
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

La commande complète est donc :

```bash
zig build-exe nanocraft.zig -lc -I/ucrt64/include -L/ucrt64/lib -lraylib.dll -lglfw3.dll -lwinmm
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

Les DLL nécessaires et terrain.png doivent être accessibles par Windows lorsque :

```text
nanocraft.exe
```

est lancé.

Une solution simple est de placer les DLL nécessaires et terrain.png directement à côté de :

```text
nanocraft.exe
```

> Ne pas copier automatiquement tout le contenu de `/ucrt64/bin`. Seules les DLL nécessaires au programme doivent être rendues disponibles.

