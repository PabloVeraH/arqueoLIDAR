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
Seguir los pasos 3 y 4 de `docs/prompt_esteban.md`: compilar, probar sitios con GPS,
borrar sitios y expedientes, y revisar Diagnóstico en Debug y en Release.
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
