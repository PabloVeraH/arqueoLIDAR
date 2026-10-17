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

### M5 · 2026-10-17 · `c0f48bd`, `48c4570` · Compilar y testear el volumen
`swift build && swift test` (suite "medición en la ficha (medido vs. inferido)", 6 pruebas).
Si falla "Domo abierto…", revisa primero que `MeshCloser` deje estanca la combinación de
domo y suelo; no relajes la etiqueta INFERIDO. Después compila la app con `xcodebuild`.
Puntos de riesgo: `UI/VolumeViews.swift` (deslizadores con `WritableKeyPath` sobre
`SIMD3<Float>`, el `switch` sobre `VolumeError?` en `message`), `MeshViewer` (ahora arma la
escena en `onAppear`) y que los cuatro botones de la captura quepan en un iPhone angosto.
**Bien si:** todo en verde y sin advertencias nuevas.

### M6 · 2026-10-17 · `48c4570` · Probar el volumen en el iPhone
1. Captura de un objeto de medidas conocidas (una caja de cartón medida con huincha)
   sobre el suelo: «Marcar» con la mira sobre la caja → guardar con propósito
   "Registro inicial" → ficha → Medir volumen: la caja naranja aparece sobre el objeto.
   Ajusta la caja, toca Calcular: debe salir **MEDIDO**. Anota el valor contra
   largo×ancho×alto.
2. El mismo objeto guardado como "Inventario de especímenes": debe salir **INFERIDO** con
   el texto de aristas tapadas, o un error claro si no se pudo cerrar la malla (anota cuál).
3. "Evaluación de daño" sobre una superficie con un hueco conocido (por ejemplo, un balde
   de arena con un hoyo de volumen medido): **INFERIDO** y valor cercano.
4. Caja sin suelo alrededor → mensaje "No se encontró el suelo…", nunca un número.
5. Guardar y sellar → pide Face ID; vuelve a la ficha con la medición listada; Verificar
   el expediente → **Íntegro**. Cancelar Face ID no deja `measurements/MSR-…json` suelto.
6. Un escaneo antiguo (sin marca) → la caja parte cubriendo todo el escaneo.
**Bien si:** las etiquetas salen como se describe. Anota en `registro_pruebas.md` los
valores contra la huincha (esto alimenta la Fase 16).

### M7 · 2026-10-17 · `4989ca7`, `734b4de` · Custodia en palabras e historial de sellos
`swift test` (suite "historial de sellos", 2 pruebas; las de custodia existentes deben
seguir verdes con el nuevo `CustodyError.fileMissing`). Compila la app; punto de riesgo:
`Findings/CustodyText.swift` (expresiones `switch`) y el `ForEach(history.reversed(), …)`
de `FindingDetailView`. En el iPhone:
1. Un hallazgo con 2 escaneos y 1 medición → "Historial de sellos (3)": el más reciente
   arriba, cada uno dice qué incorporó y "Firmado con el chip seguro…".
2. Copia el expediente a la Mac, altera 1 byte de un `mesh.ply`, devuélvelo con Archivos
   y toca Verificar → "Se modificó el modelo 3D del escaneo «…» del …". El desplegable
   "Detalle técnico" muestra la ruta exacta.
3. Borra un `geo.json` → "Falta las lecturas GPS del escaneo…". Agrega un archivo
   cualquiera a la carpeta → "Se agregó el archivo … sin sellarlo".
**Bien si:** ningún mensaje muestra términos internos (`hashMismatch`, `prevSealHash`…)
fuera del desplegable.

### M8 · 2026-10-17 · punto 1 de custodia · Verificación por un tercero sin la app
Compila: `arqueoLidar/Resources/verify_chain.py` debe quedar dentro de la app (Xcode lo
toma por la carpeta sincronizada; si no, agrégalo a "Copy Bundle Resources").
`swift test` (2 pruebas nuevas en PersistenceTests). En el iPhone, sella un escaneo y
copia el expediente a la Mac. Ahí:
1. `seals/` contiene `chain.jsonl`, `SHA256SUMS` y `verify_chain.py`.
2. En la carpeta del expediente, `shasum -a 256 -c seals/SHA256SUMS` → todo OK.
3. `pip3 install cryptography && python3 seals/verify_chain.py .` → "VERIFICACIÓN: OK".
4. Altera 1 byte de un `mesh.ply`: el paso 2 da FAILED y el 3 da FALLO con el archivo.
5. Lee `VERIFY.txt` como si no conocieras la app: ¿basta para hacer 2 y 3 sin ayuda?
**Bien si:** todo lo anterior. Si `verify_chain.py` no aparece en `seals/`, el recurso no
quedó en la app.

### M9 · 2026-10-17 · punto 2 de custodia · Firma v3 y hora del GPS
`swift test`: en CustodyTests cambian `sealProducesValidRecord` (ahora espera v3) y hay 2
pruebas nuevas ("editar la lectura GPS…", "Un sello v2…"). `python3 tools/test_verify_chain.py`
→ 12/12. En el iPhone: sella un escaneo al aire libre, copia el expediente a la Mac y
revisa el último sello en `seals/chain.jsonl`: debe tener `"signatureVersion":3` y
`"gnssTime"` igual al `timestamp` de su `geo`. `python3 seals/verify_chain.py .` → OK.
**Bien si:** todo verde. Si la firma v3 falla solo en el iPhone, sospecha de una
diferencia entre lo que se firma (`SealPayload.bytes`) y lo que escribe `appendSeal`.

### M10 · 2026-10-17 · punto 3 de custodia · Sellar antes / después de intervenir
Compila `UI/CustodyViews.swift` y los `label` ahora `nonisolated` de `FieldStore.swift`
(los usa `CustodyText`, que es `nonisolated`; si el compilador se queja de aislamiento,
es aquí). En el iPhone, en un hallazgo con escaneos:
1. «Sellar estado actual» → "Antes de intervenir" + nota → Sellar → pide Face ID.
2. El historial muestra «Sello «Antes de intervenir»: <nota>» con fecha. Verificar → Íntegro.
3. Al aire libre, el último sello en `chain.jsonl` lleva `geo` y `gnssTime`; bajo techo,
   sin GPS, igual sella.
4. Cancelar Face ID → no queda `notes/NOTE-….json` suelto; el expediente sigue Íntegro.
**Bien si:** todo lo anterior.

### M11 · 2026-10-17 · punto 4 de custodia · Reemplazar un escaneo
Compila (`CaptureView(finding:replacing:)`, `ScanSession.supersedesReason`). En el iPhone:
1. Ficha de un escaneo → «Reemplazar este escaneo» → captura → el formulario muestra
   "Reemplaza a …" y no deja guardar sin motivo; el propósito viene igual al original.
2. Tras guardar, en la lista del hallazgo el original dice "Reemplazado por el escaneo
   del … (sigue sellado)" y el nuevo "Reemplaza al escaneo del …: <motivo>".
3. El original ya no ofrece reemplazarse otra vez; Verificar → Íntegro.
**Bien si:** todo lo anterior.

## Resueltas

_(vacío)_
