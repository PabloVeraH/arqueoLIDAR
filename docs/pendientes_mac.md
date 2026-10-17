# Pendientes solo para Mac (y iPhone)

Cola de tareas que **no se pueden hacer en Windows**: compilar con Xcode o `swift`,
correr los tests del paquete, instalar en el iPhone, probar ARKit, LiDAR, Face ID o
el chip seguro, o usar herramientas que existen solo en macOS.

No es la lista general de la app (esa es `docs/faltantes.md`). Los resultados con
números se anotan en `docs/registro_pruebas.md`; aquí solo se marca el estado.

## Cómo se usa

- **En Windows (o Linux):** si escribes algo que no puedes compilar o probar, agrega
  aquí una tarea en el mismo commit. Pon qué cambió, en qué commit y cómo se verifica.
- **En la Mac:** después de sincronizar (AGENTS.md §1), haz las tareas pendientes en
  orden. Cuando una quede resuelta, muévela a "Resueltas" con la fecha, el resultado y
  el commit del arreglo, si hubo. Si falla y no puedes arreglarla, déjala en
  "Pendientes" y anota qué pasó.
- **Formato:** `M<n>` · fecha · commit de origen · qué hacer · cómo saber que está bien.
  Los números no se reutilizan.

## Pendientes

### M1 · 2026-10-15 · `d44ac6f`, `8825f72` · Sitios, borrado protegido y Diagnóstico solo en Debug
Escrito en Windows, nunca compilado. Qué cambió: Terreno abre en `SitesListView`; se
puede crear o editar un sitio (`SiteFormView`) con "Tomar ubicación con GPS"; un sitio se
borra solo si no tiene hallazgos (`FieldStore.deleteSite`); `Site.location: GeoFix?`;
cada hallazgo guarda `site.json` dentro del expediente; un hallazgo se borra solo si
**no** verifica como íntegro (`FieldStore.deleteIfNotIntact`); la pestaña Diagnóstico
existe solo en `#if DEBUG`.

1. **Compilar:** `swift build && swift test` en `PaleoRegistro/`,
   `Scripts/check_module_boundaries.sh`, `Scripts/test_module_boundaries.sh` y
   `xcodebuild -project arqueoLidar.xcodeproj -scheme arqueoLidar -destination 'generic/platform=iOS' build`
   (confirma el scheme con `xcodebuild -list`). Puntos de riesgo en `FieldViews.swift`:
   los dos `.sheet` de `SitesListView`, el `if let` dentro de `.sheet`, el `if` dentro de
   `.toolbar`, el init de `SiteFormView` con `State(initialValue:)`, el `@State` de
   `LocationRecorder` dentro de `SiteFormView` y las interpolaciones en `Text`. No
   silencies las advertencias de concurrencia con `@unchecked Sendable`.
2. **Probar en el iPhone, instalando desde Xcode (Debug):**
   a. Hay dos pestañas, Terreno y Diagnóstico. En Diagnóstico corre todas las pruebas:
      deben pasar, y debe decir "Estructura de Trabajo" en lugar de "Domain".
   b. Terreno muestra "Hallazgos sin sitio (N)" con los expedientes anteriores.
   c. Crea un sitio al aire libre, toca "Tomar ubicación con GPS", espera lecturas y toca
      "Usar esta ubicación": debe mostrar lat/lon/altura/precisión, y la fila ya no dice
      "sin ubicación". Anota la precisión.
   d. Desliza el sitio → Editar: cambia el nombre, vuelve a tomar el GPS y guarda.
   e. Dentro del sitio: crea un hallazgo, escanea, guarda y verifica: debe dar Íntegro.
   f. Edita el sitio de nuevo, vuelve al hallazgo y verifica: debe seguir Íntegro.
   g. Eliminar un sitio con hallazgos → "No se eliminó". Un sitio vacío sí se elimina.
   h. En "Hallazgos sin sitio": uno con sellos inválidos (23:04, 23:06, 23:15) se borra;
      FND-D820CF5D (íntegro) → "No se eliminó".
   i. En Archivos → En mi iPhone → ArqueoLiDAR: existe `Sites/SIT-….json`, y el hallazgo
      nuevo tiene `Findings/FND-…/site.json`.
   j. En Release (Edit Scheme → Run → Build Configuration → Release), la app abre directo
      en Sitios, sin pestañas ni Diagnóstico.

**Bien si:** compila sin errores y los pasos a–j dan lo esperado.

### M2 · 2026-10-17 · `3d63b17` · Compilar y testear la firma v2 (paquete)
`cd PaleoRegistro && swift build && swift test`. Suite nueva: "F10 Custody: firma v2 y
rotación de clave" (7 pruebas). Además `python3 tools/test_verify_chain.py` (necesita
`pip install cryptography`).
**Bien si:** todo en verde. Si algún test de custodia falla, revisa primero
`SealPayload` (SealSigner.swift), que es el formato compartido con `verify_chain.py`.

### M3 · 2026-10-17 · `fbe49da` · Compilar la app con SealingKeyStore
`xcodebuild -project arqueoLidar.xcodeproj -scheme arqueoLidar -destination 'generic/platform=iOS' build`.
Puntos de riesgo en `arqueoLidar/Findings/SealingKeyStore.swift`:
`evaluateAccessControl` async, `SecureEnclave.P256.Signing.PrivateKey(accessControl:authenticationContext:)`,
`@unchecked Sendable` en `SecureEnclaveSigningKey` y `ScanController.resume()`.
**Bien si:** compila sin errores ni advertencias nuevas.

### M4 · 2026-10-17 · `fbe49da` · Probar la firma con chip seguro en el iPhone
Seguir la lista "Pendiente: firma con chip seguro" de `docs/registro_pruebas.md`:
pide Face ID; cancelar no pierde la malla ni deja carpetas sueltas; el código sirve de
respaldo; un expediente antiguo (v1) + sello nuevo sigue Íntegro; `verify_chain.py` OK
en la Mac; el simulador sella con "Clave de software".
**Bien si:** todo da lo esperado. Anota el resultado en `registro_pruebas.md`.

## Resueltas

_(vacío)_
