# Prompt para el asistente de Esteban

Copiar todo el bloque de abajo y pegarlo en el asistente de código (Claude Code u otro),
abierto en la carpeta del repo `arqueoLIDAR` en la Mac.

```
Contexto: trabajas en el repo arqueoLIDAR (app iOS "PaleoRegistro" para registro LiDAR
de hallazgos arqueológicos/paleontológicos, Ley 17.288 Chile). Otra sesión de LLM, sin
acceso a Xcode ni a un Mac, integró cambios en la rama `feat/arreglosEsteban` y los
subió a GitHub (HEAD = 8170dc8). Ese código NUNCA se ha compilado. Tu trabajo es
actualizar tu copia local, compilar, corregir lo que falle y verificar en un iPhone Pro.

## 1. Qué cambió en la rama (lee esto antes de tocar nada)

- Merge de `origin/dev` (4861afb): arreglos de ICP (error 0,20 m → ~2 mm),
  PLYCodec con colores/normales, IntegrationTests reales, guarda de arquitectura en CI,
  check_utm.py contra el UTMConverter real. Se adaptó `ModuleSelfTests.swift`:
  `RegistrationError.degenerate` ahora tiene 2 valores asociados, y el autotest de
  "ICP recupera transformación" usa umbral 5 mm y `denseCube(divisions: 8)`, igual que
  RegistrationTests. `EndToEndTests.swift` importa CryptoKit/Crypto con la misma guarda
  `#if canImport(CryptoKit)` que Custody.
- Flujo de terreno (0d3722a) + merge con tu commit ea640f8 (8170dc8):
  - SE CONSERVA TU CAPTURA: ScanController, MeshAnchorReader, WireframeRenderer,
    CaptureView, SavedScanView y tu `tools/verify_chain.py` (reemplazó al de dev).
  - SE ELIMINARON `Findings/FindingService.swift` y `UI/FindingsView.swift`. Los
    reemplaza `Findings/FieldStore.swift` (enum `nonisolated`, sin actor), que permite
    VARIOS escaneos por hallazgo. Antes cada escaneo creaba un hallazgo nuevo.
  - `CaptureView` ahora es `CaptureView(finding:)`. El formulario de guardado pide
    `ScanPurpose` y muestra el estado del GPS (ya no pide título ni autor, que vienen
    del Finding). Llama a `FieldStore.saveScan(parts:fixes:purpose:finding:)`, que
    devuelve `SavedScan`.
  - Nuevo `Capture/LocationRecorder.swift` (CLLocationManager): serie completa de
    GeoFix durante la captura, se ve en el HUD y se guarda en `scans/<id>/geo.json`.
  - Nuevo `Rendering/MeshViewer.swift`: visor SceneKit offline de un escaneo guardado.
  - `UI/FieldViews.swift`: lista de hallazgos, alta de hallazgo (claves AppStorage
    `authorName`/`authorRole`/`authorInstitution`, las mismas que usabas), ficha del
    hallazgo, detalle del escaneo con visor 3D y exportación.
  - `ArqueoLidarApp` usa un TabView: "Terreno" (FindingsListView) y "Diagnóstico"
    (ContentView, que volvió a ser solo el autodiagnóstico).
  - Cambio en el núcleo: `Custody/Hasher.buildManifest` calcula la ruta relativa con
    `resolvingSymlinksInPath()` en ambos lados. En iOS el contenedor puede aparecer
    como /var/… o /private/var/…, y sin esto la ruta "relativa" del manifiesto salía
    absoluta.

Decisiones deliberadas que NO debes revertir sin una razón concreta y verificada:
- Las exportaciones van a `Documents/Exports/FND-…/<scan>/`, FUERA del expediente.
  Un archivo nuevo dentro del bundle sellado hace que ChainVerifier lo reporte como
  "archivo añadido no declarado".
- `.sealed` se escribe ANTES de sellar (Hasher solo excluye el `.sealed` de la raíz,
  no el de `scans/<id>/`). Tú ya hacías lo mismo.
- La firma sigue usando `SoftwareSigningKey`, una por arranque de la app. Secure
  Enclave + Face ID queda pendiente (F10).

## 2. Actualizar tu copia

1. `git status`. Si tienes cambios sin commitear, haz commit (o stash) ANTES de
   seguir. No los pierdas.
2. `git fetch origin && git checkout feat/arreglosEsteban && git pull --no-rebase`.
   Si hay conflictos, resuélvelos conservando la estructura descrita arriba e
   integrando tu trabajo nuevo encima. Nunca hagas `push --force`.
3. En Xcode: File → Packages → Reset Package Caches si falla la resolución del paquete
   local `PaleoRegistro`.

## 3. Compilar y corregir

1. Paquete: `cd PaleoRegistro && swift build && swift test`. Todo debe pasar. Si algo
   falla, distingue si es un bug real o un test mal construido (fixes.md documenta
   ambos casos) antes de "arreglar" el test.
2. Guarda de arquitectura: ejecuta `Scripts/check_module_boundaries.sh` y
   `Scripts/test_module_boundaries.sh`.
3. App: `xcodebuild -project arqueoLidar.xcodeproj -scheme arqueoLidar -destination
   'generic/platform=iOS' build` (confirma el nombre del scheme con
   `xcodebuild -list`). Corrige errores con el cambio mínimo y en el archivo correcto.
   El target usa Swift 5 mode con `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
   Puntos con más riesgo de error de compilación, porque se escribieron sin
   compilador:
   - `FieldStore.verify`: catch con typed throws (`error as? CustodyError`).
   - `LocationRecorder`: métodos delegate `nonisolated` + `MainActor.assumeIsolated`.
   - `FieldViews.swift`: interpolaciones dentro de `Text(...)`, `ShareLink(items:)`
     con `[URL]`, y `switch` sobre `CustodyVerdict` dentro de un ViewBuilder.
   - `MeshViewer`: `SceneView(scene:pointOfView:options:)` y la aritmética con
     `SCNVector3`.
   - `CaptureView`: `ForEach(ScanPurpose.allCases, id: \.self)` con `$0.label`.
   Trata también los warnings de concurrencia; no los silencies con
   `@unchecked Sendable` salvo que esté justificado.

## 4. Verificar en un iPhone Pro (no des nada por bueno sin esto)

1. Pestaña Diagnóstico → "Probar todos los módulos": deben pasar todas las
   verificaciones. Anota el error de ICP en mm.
2. Terreno → crear hallazgo → escanear un objeto conocido (una caja de dimensiones
   medidas con huincha). Confirma que el HUD muestra lecturas GPS, guarda y revisa
   SavedScanView.
3. En la ficha del hallazgo → "Verificar expediente" → debe decir Íntegro.
4. Haz un SEGUNDO escaneo en el mismo hallazgo → vuelve a verificar → debe seguir
   Íntegro, y chain.jsonl debe tener 2 sellos encadenados.
5. Abre el escaneo: el visor 3D debe mostrar la malla encuadrada. Exporta: deben
   generarse los 5 formatos + `record.json` (GeoJSON solo si hubo GPS), y aparecer en
   Archivos → En mi iPhone → ArqueoLiDAR → Exports.
6. Después de exportar, verifica de nuevo → debe seguir Íntegro. Esto prueba que las
   exportaciones no contaminan el bundle sellado.
7. Copia la carpeta `Findings/FND-…` al Mac y ejecuta
   `pip install cryptography && python3 tools/verify_chain.py <carpeta>`: debe dar
   OK con código 0. Luego altera 1 byte de `mesh.ply` en una copia → debe dar FALLO.
8. Abre `malla.ply` en MeshLab/CloudCompare, `replica_mm.stl` en un slicer y
   `nube.las` en QGIS. Compara las dimensiones de la caja contra la huincha: STL en
   mm, el resto en m.
9. Prueba con el GPS denegado y en interior (sin señal): el escaneo debe guardarse
   marcado "Sin GPS" o "GPS degradado", y la exportación debe omitir solo el GeoJSON.

## 5. Entregar

- Commits pequeños con mensajes en español, al estilo del repo
  (`fix(app): …`, `fix(custody): …`), terminando con la línea Co-Authored-By de
  tu asistente.
- Si algún punto del paso 4 falla en el núcleo (Custody, Hasher, PLYCodec), arréglalo
  en la causa raíz y agrega un test en PaleoRegistro/Tests que lo cubra.
- Actualiza `docs/informe_general.md` si cambia lo que la app hace o deja de hacer.
  Está escrito para un paleontólogo o arqueólogo sin conocimientos técnicos;
  mantén ese tono.
- Haz push a `feat/arreglosEsteban` (sin force) y entrega un resumen: qué compiló a
  la primera, qué tuviste que corregir, el resultado de cada punto del paso 4 (con
  números: error ICP, σ de ruido, dimensiones medidas vs. huincha) y qué queda
  pendiente.
```
