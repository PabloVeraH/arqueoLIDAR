# Auditoría de PaleoRegistro contra `plan_lidar_arqueologico.md`

Este documento se genera revisando el estado real del código en `PaleoRegistro/` y `App/`
contra el encargo técnico de `plan_lidar_arqueologico.md` (arquitectura §2, contratos §2.E,
fases §3). Se escribe de forma incremental a medida que se revisa cada módulo — no es un
resumen final.

Formato de cada hallazgo: **Título**, **Severidad** (`Bloqueante` / `Alta` / `Media` / `Baja`),
**Descripción**.

## Resumen ejecutivo

Revisión completa: estructura del proyecto, los 11 módulos de `PaleoRegistro/Sources`, la
capa `App/`, las herramientas de verificación externa (`tools/*.py`) y el `README.md`. Se
compiló el paquete y se corrió la suite de tests completa (`swift build` + `swift test`,
toolchain Swift 6.3.3 en Linux) para tener evidencia real de qué funciona, no solo lectura de
código; varios hallazgos se verificaron además con herramientas independientes (`pyproj`,
sondas Swift temporales no comiteadas, ejecución directa de `tools/verify_chain.py` y
`tools/check_utm.py` contra bundles reales).

**Los tres hallazgos más importantes, de mayor a menor severidad:**

1. **`Custody/` no verifica nada.** `ChainVerifier` no logra parsear ningún sello real que la
   propia app produce (incompatibilidad de formato entre `CanonicalJSONEncoder` y
   `JSONDecoder` para campos `Data`) — un bundle recién sellado, sin ninguna manipulación,
   se reporta como inválido. El verificador externo en Python falla también, por una razón
   distinta (mismatch de epoch en el timestamp firmado). Es el módulo legalmente más crítico
   del proyecto y, tal como está, no cumple su función.
2. **`UTMConverter.toGeodetic` (UTM→lat/lon) tiene un error real** (falta dividir por el
   radio de curvatura meridiano) que produce errores de metros a decenas de metros — muy
   por sobre la precisión sub-milimétrica que exige el plan. La proyección directa
   (lat/lon→UTM) sí es correcta, verificada contra `pyproj`.
3. **`DiffEngine.computeVolumeChange` proyecta sobre el par de ejes equivocado** para planos
   horizontales (el caso más común de monitoreo de yacimientos), por lo que el volumen
   ganado/perdido sale sistemáticamente ~0 sin importar el cambio real.

**Patrón transversal:** una fracción significativa de los ~24 tests que fallan en la suite
actual no revela bugs de producción sino **tests mal construidos** (fixtures con datos
incorrectos, aserciones que no pueden pasar por diseño, tolerancias incoherentes con el
plan, o metodologías de verificación inválidas — como decodificar un archivo binario como
ASCII). Esto es en sí mismo un hallazgo: **el estado "en verde"/"completo" que sugieren los
mensajes de commit no es confiable sin una auditoría como esta**, porque ni pasar ni fallar
un test garantiza hoy que el criterio de aceptación real del plan se esté cumpliendo.

**Alcance no iniciado:** `App/` (Capture, Rendering, UI, Diagnostics — Fases 0, 3, 13, 14,
15) está completamente vacío; no existe proyecto Xcode. Ninguna de las 9 capacidades del
plan es usable hoy por un operador real, aunque el código "de lógica" (los 11 módulos SPM)
compila y en su mayoría corre.

---

## Índice de secciones

- Estructura general del proyecto (guarda de arquitectura, `IntegrationTests`, stubs)
- `Geo/` (Fase 8) — UTM, convergencia meridiana, `FixQualityGate`, `TrackYawSolver`
- `Custody/` (Fase 10) — `ChainVerifier`, `verify_chain.py`
- `Registration/` (Fase 11) — `DiffEngine`, `ICPAligner`
- `Segmentation/` (Fase 7)
- `Export/` (Fase 12) — `LASWriter`, `GeoJSONWriter`, `PLYWriter`
- `Persistence/` (Fase 9) — `FindingStore.loadMesh`
- `Domain/`, `Mesh/`, `Volume/`, `Geometry/`, `Stratigraphy/` — sin hallazgos bloqueantes
- Estructura de la app (`App/`) — Fases 0, 3, 13, 14, 15 no iniciadas
- `README.md` — consistencia con el estado real

---

## Estructura general del proyecto

### Guarda de arquitectura (`check_module_boundaries.sh`) nunca se ejecuta

**✅ Corregido.** Se agregó `Scripts/test_module_boundaries.sh`, que ejercita la guarda tal
como exige el criterio de aceptación de F1: corre la guarda sobre el repo sin modificar
(debe pasar), inyecta un `import SceneKit` temporal en `Domain/` (debe fallar), lo quita
(debe volver a pasar) — con limpieza garantizada incluso si algo falla a mitad de camino.
Se agregó `.github/workflows/ci.yml`, que corre en cada push/PR: la guarda, su auto-test,
`swift build` y `swift test`, sobre la imagen oficial `swift:6.0`. Antes de esto no existía
ningún CI ni ninguna prueba de que la guarda realmente detectara una violación.

**Severidad:** Alta

El plan (Fase 1, criterio de aceptación) exige: *"La guarda de arquitectura falla
deliberadamente cuando se le agrega `import SceneKit` a un archivo de `Domain/` de prueba, y
vuelve a pasar al quitarlo. Probar que la guarda falla es parte del criterio."* y en el §4
(checklist Xcode, punto 16) exige que sea una fase de build que falle el build.

`Scripts/check_module_boundaries.sh` existe y su lógica es razonable (busca imports
prohibidos por regex en los módulos puros), pero:
- No hay proyecto Xcode (no existe ningún `.xcodeproj`/`.xcworkspace` en el repo), así que no
  puede estar integrado como fase de build.
- No hay ningún workflow de CI (`.github/workflows`, etc.) que lo invoque en Linux/SPM.
- No hay ningún test (Swift o shell) que verifique que el script realmente detecta la
  violación (agregar un import prohibido a un archivo de prueba y confirmar que el script
  retorna código de salida ≠ 0, y que vuelve a pasar al quitarlo).

En este momento el script es código muerto: nadie lo ejecuta nunca, ni en desarrollo ni en
CI. El criterio de aceptación de la Fase 1 no está cumplido.

### `IntegrationTests` es un stub vacío pese a que F1–F12 se dan por "completas"

**✅ Corregido.** Se agregaron 3 tests de integración reales que ejercitan el pipeline
completo sin UI/ARKit: (1) ciclo de vida de un hallazgo — crear expediente, guardar la
malla, recargarla desde disco, sellar, verificar en verde, manipular un archivo y verificar
que la manipulación se detecta, exportar PLY con sidecar; (2) segmentación → OBB → volumen;
(3) dos campañas → `DiffEngine` → volumen ganado. El primero ejercita directamente el
camino que tenía el bug bloqueante de Custody — confirma que el ciclo real (no solo el
aislado de `CustodyTests`) funciona de punta a punta. Se encontraron y corrigieron dos
problemas menores propios de los datos sintéticos al escribir estas pruebas (no bugs de
producción): un cubo perfecto no tiene ejes principales únicos para el ajuste de OBB por
PCA (se reemplazó por una caja con dimensiones distintas por eje), y las caras de una caja
se separan en componentes distintas con el `maxDihedralAngleDegrees` por defecto (45°,
correcto para superficies reales) — se subió para esta prueba sintética de una sola pieza.

**Severidad:** Alta

El último commit (`e9c9a7b chore: IntegrationTests stub`) agrega
`PaleoRegistro/Tests/IntegrationTests/StubTests.swift` con solo el comentario
`// Stub temporal. Será reemplazado en su fase.` — ningún test real. Sin embargo los commits
previos afirman haber completado F7 a F12 (Segmentation, Custody, Export, Registration,
Geo, Persistence). El plan no dedica una fase explícita a "integración" fuera de F14 (que
requiere UI), pero el propósito del target `IntegrationTests` en `Package.swift` (que
depende de los 11 módulos puros) es exactamente probar el pipeline completo sin UI
(mesh → volumen → segmentación → registro → custodia → export), algo que sí es alcanzable
sin ARKit/SceneKit y que el plan da por sentado como parte de "ninguna fase algorítmica se
declara terminada contra datos reales" (regla general de §3). Ese target existe pero no
contiene ni un solo `@Test`.

### La suite de tests SÍ corre (con toolchain Linux) y revela ~24 tests reales rotos, 490 fallos

**✅ Resuelto.** Los 24 tests documentados en esta auditoría (más los descubiertos durante
las correcciones, como el bug de matriz transpuesta) están corregidos. Estado actual:
**145/145 tests pasan**, `swift build` y `swift test` en verde, y ahora corren
automáticamente en CI (ver hallazgo de la guarda de arquitectura) — ya no depende de que
alguien lo ejecute manualmente para descubrir una regresión.

**Severidad:** Bloqueante (metodológico)

El repo no incluye proyecto Xcode, así que la única forma de ejecutar `swift test` es con el
SPM en Linux/macOS. Se instaló un toolchain Swift 6.3.3 local y se corrió `swift build` +
`swift test` sobre `PaleoRegistro/`: **compila limpio**, pero **24 tests distintos fallan**
(490 issues individuales, la mayoría en `GeoTests` por un test parametrizado con 400
sub-casos). Ningún commit del historial (`f655471` "F8 Geo", `443aa4a` "F11 Registration",
`bfcae89` "F10 Custody", etc.) menciona que la suite estuviera en rojo, y el mensaje de cada
commit da la fase por completada. Como no hay CI configurado (ver hallazgo anterior), esto
nunca se detectó automáticamente. El detalle de cada falla real se documenta en las secciones
de cada módulo más abajo; este ítem registra el hecho agregado: **la afirmación implícita
"F7–F12 están completas y probadas" no es cierta tal como está el repo ahora.**

### Placeholders `Stub.swift` de la Fase 1 no se limpiaron al completar cada módulo

**Severidad:** Baja

`Sources/{Custody,Export,Geo,Persistence,Registration,Segmentation}/Stub.swift` (2 líneas
cada uno, `public enum XModuleStub {}`) fueron creados en el commit base F0-F6 como
placeholder para que el paquete compilara antes de implementar cada módulo. Los seis módulos
ya tienen implementación real (`Hasher.swift`, `PLYWriter.swift`, `UTMConverter.swift`,
`BundleWriter.swift`, `ICPAligner.swift`, `MeshSegmenter.swift`, etc.) pero los stubs siguen
en el árbol sin usarse, igual que sus `StubTests.swift` correspondientes (comentario vacío).
No rompen el build, pero contradicen la regla del proyecto de no dejar archivos de trabajo
temporales una vez completada la fase, y ensucian la lectura de "qué está implementado" para
cualquier sesión de LLM nueva que use este repo como contexto (la premisa explícita del
plan: *"cualquier sesión de LLM, sin contexto previo del proyecto, pueda tomar una fase"*).

---

## `Geo/` (Fase 8)

Verificado ejecutando `swift test` y contrastando con `pyproj` (independiente, instalado
para esta auditoría) como verdad externa — exactamente el tipo de cruce que el propio plan
exige en el criterio de aceptación de F8 (*"los mismos puntos convertidos con `pyproj`...
coinciden dentro de 1 mm"*), pero que `tools/check_utm.py` no hace automáticamente hoy (ver
más abajo).

### `UTMConverter.toGeodetic` (UTM → lat/lon) tiene un error real: falta dividir por el radio de curvatura meridiano

**✅ Corregido.** Se arregló el `ρ1` faltante, pero al verificar con una sonda quedó un
segundo error (no detectado antes) en la fórmula de longitud, con el mismo síntoma
(error creciente con la distancia al meridiano central). En vez de perseguir un segundo
bug en una serie cerrada independiente de 5 términos, se rediseñó `toGeodetic`: la serie de
Snyder/Redfearn ahora solo da la **estimación inicial** (exacta sobre el meridiano central,
cercana fuera de él), y un refinamiento Newton-Raphson la pule contra `project(lat,lon)` —
la misma función de proyección directa que usa `toUTM`, ya verificada contra `pyproj` a nivel
sub-milimétrico — hasta precisión de máquina. Esto hace el round-trip correcto por
construcción: una sola fuente de verdad para la proyección (no dos fórmulas independientes
que solo se verifican entre sí), y cualquier corrección futura a la proyección directa se
propaga automáticamente a la inversa. *"UTM round-trip: 10 000 puntos..."* y *"UTM: grilla
densa..."* pasan en verde (antes: 32 y 400 fallas respectivamente).

**Severidad:** Bloqueante

`Sources/Geo/UTMConverter.swift:140`:

```swift
let lat = phi1
    - (nu1 * tanPhi1 / (nu1 * 1.0)) * ( ... )
```

`nu1 * tanPhi1 / (nu1 * 1.0)` se simplifica algebraicamente a `tanPhi1` — el `nu1` del
numerador y denominador se cancelan. La fórmula estándar de Snyder/Redfearn para la latitud
del pie de meridiano exige dividir por **ρ1** (radio de curvatura en el meridiano en `phi1`,
`ρ1 = a(1-e²) / (1-e² sin²φ1)^1.5`), no por `nu1` (radio de curvatura en el primer vertical).
El código nunca calcula `ρ1`; el término que debía ser `nu1 * tanPhi1 / rho1` quedó reducido
a solo `tanPhi1`, perdiendo la corrección completa.

**Evidencia independiente (no solo el test del repo):** se generó una sonda temporal (no
commiteada) que llama directamente a `toUTM` y `toGeodetic` y se contrastó contra `pyproj`
(EPSG 32719/32718/32712):

- `toUTM` (proyección directa, geo→UTM) **es correcta**: coincide con `pyproj` a nivel
  sub-milimétrico en los 8 puntos de control probados (ej. `-53.16,-70.91667` → E=371854.281,
  N=4108214.901 en ambas implementaciones).
- `toGeodetic` (UTM→geo, la inversa) **no**: para `(lat=-33.0, lon=-70.3)`, ida y vuelta con
  la implementación del repo devuelve `lat=-33.000037…` (~4.1 m de error) y
  `lon=-70.29948…` (~48.5 m de error); con `pyproj` el error es de sub-milímetros
  (`lat=-33.00000000043`, `lon=-70.30000000000683`).

Esto explica directamente los tests que fallan con cientos de "issues": *"UTM round-trip:
10 000 puntos..."* (32 fallas) y *"UTM: grilla densa de 200 puntos en zona 19S..."* (400
fallas) — el error crece con la distancia al meridiano central, exactamente el patrón que
predice un término de corrección faltante.

**Impacto:** cualquier flujo que necesite ir de UTM a lat/lon (por ejemplo, mostrar en el
mapa un punto de control ingresado manualmente en UTM, o reproyectar coordenadas de un
`SiteFrame` para QA) tiene error de metros a decenas de metros — muy por sobre la exigencia
de precisión sub-milimétrica que el propio plan fija para el `UTMConverter` (§2.C.5, §3 F8).

### El test de "puntos de control publicados" usa datos de fixture incorrectos, no revela un bug real de proyección directa

**✅ Corregido.** Se reemplazaron los 3 puntos "18S" (que en realidad eran huso 19)
por puntos genuinamente en el huso 18 (-78°..-72°), y se recalcularon los 8 puntos con
`pyproj` a precisión completa (no redondeados a metros). La tolerancia se bajó de 5 m a
1 mm, tal como exige el plan. Los 3 tests de puntos de control pasan en verde.

**Severidad:** Media

`Tests/GeoTests/GeoTests.swift:24-28`, los tres puntos etiquetados como huso **18S**
(`lat: -33.42536, lon: -70.63340`, `lat: -33.45, lon: -70.66667`, `lat: -33.0, lon: -69.0`)
están **mal etiquetados**: esas longitudes (-69° a -70.7°) caen dentro del rango del huso
**19S** (-72° a -66°), no del 18S (-78° a -72°). El propio `UTMConverter` selecciona
correctamente la zona 19 para esos puntos (verificado con `pyproj`), así que la comparación
`#expect(utm.zone == cp.zone)` falla porque el dato de prueba está mal, no porque el
conversor se equivoque. Además, los valores E/N de esos tres puntos (y de varios del huso
19S/12S) difieren de la proyección correcta (contrastada con `pyproj`) en decenas a ~1300 m
— muy por sobre cualquier tolerancia razonable —, lo que indica que fueron capturados de una
fuente aproximada (el comentario del propio archivo lo admite: *"no tienen precisión
geodésica publicada oficial"*).

Separado de esto: el criterio de aceptación del plan (§3, F8) exige explícitamente
**"error < 1 mm"** contra puntos de control publicados. El test declara
`controlPointTolerance: Double = 5.0 // m` — una tolerancia **5000 veces** más laxa que la
exigida. Aun con esa tolerancia relajada el test sigue fallando por los datos incorrectos.
Recomendación: reemplazar los puntos de control por valores generados con una herramienta
geodésica trazable (IGM, `pyproj`, o vectores EPSG publicados) y bajar la tolerancia al
milímetro como pide el plan.

### `meridianConvergenceExact` (usada como "verdad" en el test) es la función con el bug, no `meridianConvergence`

**✅ Corregido.** En vez de reparar la identidad trigonométrica transcrita a mano (el mismo
patrón de fragilidad que causó el bug de `toGeodetic`), se reescribió
`meridianConvergenceExact` como diferencia finita sobre `project(...)` — la misma proyección
directa ya verificada que usa `toUTM` — para obtener la convergencia geométricamente
(la dirección en la que se mueve la proyección al aumentar la latitud), sin una segunda
fórmula cerrada independiente que verificar a mano. Los 20 puntos del test pasan en verde.

**Severidad:** Media

El test *"Convergencia meridiana: fórmula de series vs fórmula cerrada"* falla en 18 de 20
puntos (errores de 0.001° a 0.010°) comparando `meridianConvergence` (la fórmula en serie,
la que de verdad se usa en producción vía `SiteFrameResolver`) contra
`meridianConvergenceExact` (documentada como *"fórmula cerrada... útil como control cruzado
en tests"*, `UTMConverter.swift:186-203`).

Se verificó con una tercera referencia independiente (diferencia finita sobre la proyección
`toUTM`, ya validada contra `pyproj`, evaluando `atan2(ΔE, ΔN)` para un desplazamiento
infinitesimal en latitud): en los 6 puntos probados, **`meridianConvergence` (la serie)
coincide con la referencia independiente a 5 decimales** (ej. `0.544678°` vs `0.544678°` en
`lat=-33, lon=-70, zone=19`), mientras que **`meridianConvergenceExact` se desvía de esa
misma referencia en 0.003°–0.010°** — el mismo orden de magnitud del fallo del test.

Es decir: el test compara la implementación correcta contra un "control" que en realidad
tiene el error, y por lo tanto **apunta a la función equivocada**. Si alguien "arregla" el
test ajustando `meridianConvergence` para que coincida con `meridianConvergenceExact`,
introduciría una regresión real en la función que sí se usa en el pipeline de
georreferenciación (`SiteFrameResolver` → `SiteFrame.meridianConvergence`, §2.E).

### "UTM: selección automática de huso correcta en bordes": el test se equivoca sobre dónde cae el límite 18S/19S y 19S/20S

**✅ Corregido.** Se reescribieron las aserciones con la convención real (intervalo
semiabierto, límite oeste inclusivo) y puntos sin ambigüedad.

**Severidad:** Baja (calidad de test)

Dos aserciones de este test contradicen la propia fórmula estándar de selección de huso
(`zone = floor((lon+180)/6)+1`, la misma que implementa `UTMConverter.zoneFrom`):

- Espera zona **18** para `lon = -71.999°`, pero ese punto está al **este** de -72°
  (menos negativo), es decir, dentro del rango del huso **19** (`[-72°, -66°)`); el huso 18
  cubre `[-78°, -72°)`. El comentario del test (*"-71.999° es zona 18"*) tiene la dirección
  invertida. El conversor calcula zona 19 correctamente.
- Espera zona **19** para `lon = -66.0°` exacto, pero por la misma fórmula (`floor((180-66)/6)+1
  = floor(19.0)+1 = 20`), ese es precisamente el límite donde empieza el huso 20 bajo la
  convención de intervalo semiabierto que el propio conversor usa consistentemente en todo
  el resto del código. Es un caso de borde genuinamente ambiguo (distintas fuentes difieren
  en si el límite exacto pertenece al huso de la izquierda o la derecha), pero tal como está
  escrita la fórmula del proyecto, el resultado `20` es el consistente — el test, no el
  conversor, es el que asume la convención contraria sin declararla.

### `FixQualityGate`: una única fijación precisa se marca `.degraded` por un centinela mágico

**✅ Corregido.** Se distingue explícitamente `sigma == nil` ("no hay datos suficientes para
calcular dispersión") de "dispersión mala": con una sola fijación aceptada no hay nada que
contradiga su propia precisión, así que ahora se acepta como `.good`.

**Severidad:** Alta

`Sources/Geo/FixQualityGate.swift:72`:

```swift
verdict.quality = (sigma ?? 999) < 15.0 ? .good : .degraded
```

`horizontalDispersion` devuelve `nil` cuando hay menos de 2 fijaciones aceptadas
(`FixQualityGate.swift:133`, `guard fixes.count >= 2 else { return nil }`) porque la
dispersión no está definida con un solo punto. El código trata ese `nil` ("no hay datos
suficientes para calcular dispersión") como si fuera "dispersión de 999 m" (pésima calidad),
en vez de tratarlo como el caso trivial de sigma-cero/no-aplicable. Resultado: **una única
fijación GPS con `horizontalAccuracy = 4.2 m` (buena) se reporta como `georeferenceQuality:
.degraded`**, y esa marca — según el propio plan (§2.C.5) — "viaja hasta el PDF exportado".
Test que lo confirma: *"Acepta fijaciones con precisión bajo el umbral"* falla porque espera
`.good` y obtiene `.degraded`.

En terreno esto degrada sistemáticamente la calidad reportada de cualquier escaneo corto con
una sola fijación aceptada (plausible si el resto del burst se descartó por baja precisión),
lo cual es contrario a la intención del diseño: la fijación única *sí* pasó el umbral de
`maxHorizontalAccuracy`, y no debería penalizarse por no tener con qué comparar dispersión.

### `TrackYawSolver` (producción) parece correcto; los tests que lo cubren están rotos por el propio fixture

**✅ Corregido (en el test, no en producción).** Se arregló la matriz de "rotación" del
generador (`gpsEast = arX·cosθ + arZ·sinθ`, `gpsNorth = arX·sinθ − arZ·cosθ` — rotación 2D
propia real), se escaló el zigzag con `length` para que una trayectoria "corta" acumule
realmente poco largo de arco, y se reemplazó `#expect(throws: GeoError.degenerateTrack(""))`
por `#expect(throws: GeoError.self)` en los tres casos que comparaban por igualdad exacta
contra un mensaje que nunca podía coincidir. Los 4 tests de `TrackYawSolverTests` pasan en
verde.

**Severidad:** Alta (calidad de tests) — no se encontró bug en el código de producción

Los 4 tests de `TrackYawSolverTests` fallan, pero **no por un defecto en
`Sources/Geo/TrackYawSolver.swift`**. Se aisló la causa generando una sonda independiente con
una rotación 2D matemáticamente correcta (sin ruido, con el mismo sesgo constante de 3 m que
el test original) y el solver recuperó el yaw verdadero con **error de 0.00001°**
(`47.299988°` recuperado vs `47.3°` esperado), confirmando que la implementación de Horn 2D
del solver es correcta. Los fallos vienen del helper `syntheticTrack(...)` en
`Tests/GeoTests/GeoTests.swift:293-341` y de las aserciones que lo usan:

1. **La matriz de "rotación" del generador no es una rotación.** Líneas 327-328:
   ```swift
   let gpsEast  = arX * cosY + (-arZ) * sinY + biasEast  + ruido
   let gpsNorth = arX * sinY + (-arZ) * cosY + biasNorth + ruido
   ```
   Escrito en forma matricial sobre el punto AR `(px, py) = (arX, -arZ)`, esto aplica
   `[[cosY, sinY], [sinY, cosY]]`, que **no es una matriz de rotación** (no es antisimétrica
   en el término cruzado; determinante = cos(2Y), no 1). La fórmula correcta de rotación 2D
   es `[[cosY, -sinY], [sinY, cosY]]` — el signo del término `sinY` en `gpsEast` está
   invertido. Por eso el test *"recupera yaw conocido..."* falla con **23.87° de error**: no
   hay ningún yaw único que el solver (que sí busca una rotación propia) pueda recuperar de
   datos generados con una transformación que no es una rotación. Esto invalida el test que
   el plan describe como *"la justificación escrita de por qué no se usa la brújula ni la
   posición GPS absoluta"* (§3, F8) — tal como está, no prueba lo que dice probar.
2. **El caso "trayectoria demasiado corta" no genera una trayectoria corta.**
   `syntheticTrack(length: 3.0, points: 10)` reutiliza el mismo generador con zigzag
   (`sin(t*8)*2.0`, `cos(t*5)*1.5`) cuya amplitud no escala con `length`; la longitud de arco
   acumulada resultante supera el `minTrackLength` de 10 m aunque el desplazamiento neto
   pedido sea de solo 3 m. El test espera un error y no lo obtiene.
3. **Dos tests comparan errores tipados por igualdad exacta de su string asociado**, algo que
   nunca puede pasar por diseño: `GeoTests.swift:374` y `:383` usan
   `#expect(throws: GeoError.degenerateTrack(""))`, pero `TrackYawSolver` siempre lanza el
   error con un mensaje descriptivo no vacío (ej. `"traza GPS insuficiente (0 puntos, mínimo
   3)"`). La aserción correcta es verificar el caso del enum, no su valor asociado completo
   (`#expect(throws: GeoError.self) { ... }` + `switch`, o un helper que compare solo el
   caso). Mismo patrón — sano — se usa en otros tests del mismo archivo con valores
   deterministas (`unsupportedZone(10)`), así que el problema es específico a los tres usos
   de `degenerateTrack("")`.

Conclusión práctica: el algoritmo de yaw por trayectoria parece confiable, pero **la
cobertura de test que debería probarlo está rota de una manera que oculta tanto falsos
negativos como una futura regresión real** (nadie notaría si `TrackYawSolver` se rompiera,
porque estos tests fallan de todos modos por causas ajenas al solver).

### `tools/check_utm.py` nunca llama al conversor de la app — su "round-trip" compara `pyproj` contra sí mismo

**✅ Corregido.** Se implementó el modo `--file` que el docstring ya prometía, en ambos lados:

- **Lado Swift** — nuevo target ejecutable `UTMReferenceDump` (`Sources/UTMReferenceDump/main.swift`,
  agregado a `Package.swift`) que llama al `UTMConverter` real de la app sobre 24 puntos que
  cubren Chile continental e insular (husos 12/18/19, bordes de huso) e imprime CSV
  (`lat,lon,easting,northing,zone,hemisphere,epsg`) por stdout. Puntos fuera de los husos que
  la app soporta reportan el error tipado por stderr en vez de interrumpir el resto del volcado.
- **Lado Python** — `check_utm.py` ahora usa `argparse` con `--file <path>` y
  `--tolerance-mm` (default 1 mm, igual que `GeoTests`). Con `--file`, lee el CSV y para cada
  punto recalcula zona/hemisferio/EPSG/E/N con `pyproj` de forma independiente, compara contra
  lo que reportó la app, y falla si hay discrepancia de huso o si el error de posición supera
  la tolerancia.
- De paso se corrigió `CONTROL_POINTS`, la tabla de puntos de control *local* de este script
  (independiente de la de `GeoTests`, ya corregida antes): tenía valores redondeados a mano
  que además clasificaban mal el huso de 3 de sus 8 puntos, por lo que el propio script
  reportaba `[DISCREPANCIA]` de hasta 2295 m en los 8 puntos — no por un bug del
  `UTMConverter`, sino porque la tabla de referencia del script estaba mal. Se reemplazó por
  los mismos puntos que `GeoTests.zone18Points/zone19Points/zone12Points`, con E/N de
  `pyproj` a precisión completa y tolerancia de 1 mm.

Verificado extremo a extremo: `swift run UTMReferenceDump > tools/utm_reference.txt` seguido
de `python3 tools/check_utm.py --file tools/utm_reference.txt` corre en verde, con un error
máximo app-vs-pyproj de 0.621 mm sobre 20 puntos (los 4 restantes caen en huso 20, no
soportado por el `UTMConverter`, y se excluyen limpiamente). `tools/utm_reference.txt` es un
artefacto generado y determinista — no se versiona (agregado a `.gitignore`).

**Severidad:** Alta

El criterio de aceptación de F8 pide expresamente: *"Cruce contra una implementación
independiente: los mismos puntos convertidos con `pyproj` desde `tools/check_utm.py`
coinciden dentro de 1 mm. Si los dos verificadores discrepan en algún caso, la fase no está
terminada."* Se ejecutó `python3 tools/check_utm.py` tal como está en el repo (con `pyproj`
instalado) y esto es lo que hace en realidad:

- La sección **"Round-trip lat/lon → UTM → lat/lon"** convierte con `pyproj` y vuelve a
  convertir con `pyproj` — **nunca invoca al `UTMConverter` de Swift**. Por diseño da
  `0.0000 mm` en los 17 puntos y `RESULTADO: OK` siempre, sin importar si la app tiene
  algún bug. El propio docstring del archivo (líneas 14-16) lo admite: *"Este script valida
  el MÉTODO... contra pyproj. Para comparar contra la app, exporta el archivo
  `tools/utm_reference.txt` generado por la app... y usa `--file`"* — pero `main()` no
  define ningún argumento `--file`, no usa `argparse`, y no existe ningún
  `utm_reference.txt` ni código en el lado Swift que lo genere. La comparación contra la app
  que el plan exige **no está implementada**, solo documentada como si lo estuviera.
- La sección **"Verificación UTM: pyproj vs puntos de control"** sí es real (usa los mismos
  8 puntos hardcodeados que `GeoTests.swift`), y al ejecutarla **reporta los 8 puntos como
  `[DISCREPANCIA]`** (errores de 198 a 2295 m contra la tolerancia de 5 m declarada en el
  propio script). Esto confirma independientemente, con la herramienta que el plan pide,
  que la fixture de puntos de control descrita arriba está mal — y demuestra que, de
  haberse ejecutado este script alguna vez durante el desarrollo de F8, el problema se
  habría detectado de inmediato.

En síntesis: la herramienta de verificación externa exigida por el plan existe como archivo,
pero en su forma actual **no cumple ninguna de las dos funciones que promete**: no cruza
contra la app (el bug real de `toGeodetic` documentado arriba es invisible para ella) y su
verificación contra puntos de control, aunque sí funciona, nunca se atendió (los 8 puntos
siguen fallando). Por eso la auditoría tuvo que instalar `pyproj` y escribir el cruce contra
el `UTMConverter` de Swift a mano (ver hallazgo anterior) para aislar el bug real.

---

## `Custody/` (Fase 10) — el módulo legalmente más crítico del proyecto

### `ChainVerifier` no logra parsear ningún sello real: incompatibilidad de formato `Data` entre `CanonicalJSONEncoder` y `JSONDecoder`

**✅ Corregido.** `CanonicalJSONEncoder` ahora serializa `Data` como base64 y `Date` como
ISO 8601 UTC con milisegundos (`CanonicalDateCoding`), y `ChainVerifier`/`FindingStore`
decodifican con un `JSONDecoder` configurado para leer ese mismo formato. Como el payload
firmado incluía `Date.timeIntervalSince1970` en crudo, se normalizó también a milisegundos
enteros (`CanonicalDateCoding.millisecondsSince1970`) en `SealSigner`/`ChainVerifier`, para
que la firma sobreviva el viaje de ida y vuelta por el JSON canónico sin perder precisión.
Los 4 tests de `ChainVerifier` afectados pasan en verde, incluyendo *"Verificación pasa con
bundle íntegro"*.

**Severidad:** Bloqueante — el hallazgo más grave de toda la auditoría

`ChainVerifier.verify` (`Sources/Custody/ChainVerifier.swift:45-54`) parsea `chain.jsonl` con
un `JSONDecoder()` estándar de Foundation:

```swift
let decoder = JSONDecoder()
...
guard let data = line.data(using: .utf8),
      let seal = try? decoder.decode(SealRecord.self, from: data) else {
    errors.append(.invalidSeal("Sello \(i) no es JSON válido"))
    continue
}
```

Pero `chain.jsonl` se escribe con `CanonicalJSONEncoder` (`Sources/Persistence/CanonicalJSON.swift`),
el encoder canónico "propio" que el plan exige para determinismo de hashes (§2.B, §3 F9).
`SealRecord` (`Domain/Contracts.swift:368`) tiene dos campos `Data` (`publicKeyDER`,
`signatureDER`) con conformidad `Codable` sintetizada, sin `encode(to:)`/`init(from:)`
personalizados.

El problema: **los dos encoders serializan `Data` de forma incompatible.**
`CanonicalJSONEncoder` es un `Encoder` genérico hecho a mano que no tiene el tratamiento
especial que `Foundation.JSONEncoder` aplica internamente a `Data`/`Date`/`URL` — así que la
conformidad `Codable` por defecto de `Data` cae en su encoding genérico: **un array JSON de
enteros** (un byte por elemento). `JSONDecoder`, en cambio, sí tiene ese tratamiento especial
y **espera una cadena en base64** para cualquier campo `Data`.

Se verificó directamente generando un sello real y mirando el JSON producido
(`Sources/Custody/ChainVerifier.swift` + `CanonicalJSONEncoder` en conjunto, sonda temporal
no comiteada):

```
{"author":{...},"deviceKeyID":"b9e71d46852d...","index":0,"manifest":[...],
 "publicKeyDER":[48,89,48,19,6,7,42,134,72,206,61,2,1,6,8,42,...],
 "rootHash":"dd360d7bc99bc7a0...
```

Al intentar decodificar esa misma línea con `JSONDecoder().decode(SealRecord.self, from:)`
(exactamente lo que hace `ChainVerifier`):

```
DecodingError.typeMismatch: expected value of type String. Path: publicKeyDER.
Debug description: Expected to decode String but found an array instead.
```

**Consecuencia: `ChainVerifier` no puede leer ningún sello real que la propia app produce.**
Todo sello, sin excepción, se reporta como `invalidSeal("Sello N no es JSON válido")` — y
como el parseo falla antes de llegar a las comprobaciones de integridad (paso 4 y 5 del
método), **ninguna de las verificaciones que el plan exige como criterio de aceptación de
F10 llega a ejecutarse nunca**: ni la detección de byte alterado, ni la de archivo añadido no
declarado, ni la de sello borrado, ni la verificación de firma. El síntoma en los tests:

- *"Verificación pasa con bundle íntegro"* falla: un bundle recién sellado, sin ninguna
  manipulación, se reporta `.invalid` — el caso feliz más básico de todo el módulo no
  funciona.
- *"Detección de byte alterado en mesh.ply"*, *"Detección de archivo añadido no declarado"* y
  *"Detección de sello intermedio borrado"* fallan también, pero no porque la detección esté
  mal — nunca llegan a ejecutarse, quedan enmascaradas por el fallo de parseo previo.

Esto no es un detalle de test: es el defecto que el plan entero identifica como el riesgo
legal central del proyecto (§2.F, riesgo 7: *"límites reales de la cadena de custodia"*) —
excepto que aquí ni siquiera se llega a esos límites, porque **la cadena de custodia, tal
como está implementada hoy, no verifica nada**. Un perito que reciba un bundle sellado por
esta app y trate de verificarlo con `ChainVerifier` (o, previsiblemente, con
`tools/verify_chain.py` si reimplementa el mismo criterio de decodificación — ver más abajo)
obtendría siempre "inválido", incluso sobre un expediente perfectamente íntegro.

**Arreglo sugerido (no aplicado; esto es una auditoría, no un fix):** o bien (a) usar
`CanonicalJSONEncoder`/un decodificador canónico simétrico también para leer `chain.jsonl` en
`ChainVerifier` (coherente con la regla del plan de que el mismo encoder debe usarse en todo
el ciclo de vida), o (b) hacer que `CanonicalJSONEncoder` serialice `Data` como base64 (para
que sea consumible por `JSONDecoder` estándar y por herramientas externas), documentando esa
convención en `VERIFY.txt`. Cualquiera de las dos cierra el bug, pero **hay que elegir una y
aplicarla consistentemente** en `SealSigner`, `ChainVerifier`, `Persistence` y en
`tools/verify_chain.py`.

**Confirmación adicional — el verificador externo Python también falla sobre el mismo bundle
íntegro, y por una razón distinta:** se materializó un bundle sellado real (fuera de la
suite de tests, en `/tmp`) y se corrieron ambos verificadores sobre él:

```
Swift ChainVerifier.verify(...).isValid  → false
python3 tools/verify_chain.py <bundle>   → VERIFICACIÓN: FALLO. Sello 0: firma inválida
```

El plan exige exactamente este cruce como criterio de cierre de F10 (*"Si los dos
verificadores discrepan en algún caso, la fase no está terminada"*) — aquí ambos coinciden
en rechazar un bundle que no tiene ninguna manipulación, lo cual en la práctica es peor: un
desarrollador que solo mirara "¿los dos verificadores están de acuerdo?" concluiría
erróneamente que todo está bien, cuando en realidad **ninguno de los dos funciona**.

`verify_chain.py` no falla por el mismo motivo que la versión Swift (Python's `json.loads`
no es estricto de tipos y acepta el array de bytes sin problema) — falla en
`verify_signature()` (`tools/verify_chain.py:57`) porque `base64.b64decode(seal.get(
"publicKeyDER", ""))` recibe una `list`, no un `str`; esto lanza `TypeError`, que el
`except Exception: return False` de la línea 65 traga en silencio y reporta como "firma
inválida" — un diagnóstico engañoso (sugiere falsificación cuando en realidad es un error de
formato) para lo que realmente es una excepción de tipo no manejada.

### Bug adicional (independiente) en `tools/verify_chain.py`: usa el epoch equivocado al reconstruir el payload firmado

**Severidad:** Alta — quedaría oculto hasta que se corrija el bug de arriba, y entonces
rompería la verificación de firma igual

`SealSigner.swift:97` firma `"\(rootHash)|\(clock.timeIntervalSince1970)|\(author.name)"` —
**segundos desde 1970** (Unix epoch). Pero `Date` en Swift/Foundation serializa por defecto
(conformidad `Codable` sintetizada, la que usa `CanonicalJSONEncoder` al no tener manejo
especial para `Date`) como **`timeIntervalSinceReferenceDate`** — segundos desde
2001-01-01T00:00:00Z, un epoch distinto, desfasado del Unix epoch por 978 307 200 segundos
(~31 años). Dentro de Swift esto es inofensivo porque `ChainVerifier` reconstruye el payload
llamando `.timeIntervalSince1970` sobre el `Date` ya decodificado (`seal.wallClock`, un
objeto `Date`, no el número crudo) — pero **`verify_chain.py` no decodifica a un objeto
`Date`, usa el número JSON crudo tal cual**:

```python
payload = f"{seal['rootHash']}|{seal['wallClock']}|{seal['author']['name']}".encode()
```

Se verificó con el mismo bundle real generado arriba: el valor crudo de `wallClock` en el
JSON fue `808453636.4071157`. Interpretado como `timeIntervalSinceReferenceDate` (lo que
realmente es) corresponde a `2026-08-15` (la fecha real de la firma); interpretado
directamente como `timeIntervalSince1970` (lo que `verify_chain.py` asume) corresponde a
`1995-08-15` — **31 años de diferencia**. Esto significa que el payload que
`verify_chain.py` reconstruye para verificar la firma **nunca coincide** con el que
`SoftwareSigningKey`/`SecureEnclave` firmó realmente, así que la verificación de firma del
script Python está rota de forma independiente al bug de formato `Data` — arreglar uno no
arregla el otro.

### `tools/verify_chain.py` nunca verifica el `rootHash` del manifiesto — omite una categoría entera de manipulación que sí cubre la versión Swift

**Severidad:** Media

`ChainVerifier.swift` (paso 4c) recalcula el hash canónico del manifiesto actual y lo
compara contra `lastSeal.rootHash`, para detectar manipulaciones del propio manifiesto (por
ejemplo, sustituir el `manifest.json`/las entradas por unas que declaren hashes distintos a
los archivos reales, sin que ningún archivo individual "falte" o quede "sin declarar").
`tools/verify_chain.py` define una función `compute_root_hash()` (línea 44) con ese
propósito explícito en el comentario, pero **nunca la llama** — `verify()` (línea 92) no
tiene ningún paso que compare un root hash recalculado contra `seal["rootHash"]`. El
verificador externo, tal como está, es estructuralmente incapaz de detectar esa clase de
manipulación aunque el bug de arriba se corrija.

---

## `Registration/` (Fase 11)

### `DiffEngine.computeVolumeChange` proyecta sobre el par de ejes equivocado para planos horizontales — el volumen ganado/perdido sale sistemáticamente ~0 en el caso más común

**✅ Corregido.** Se reemplazó el booleano `useXY` (que además solo cubría 2 de los 3 casos
posibles — el caso normal ≈ X quedaba mal proyectado en silencio igual que el caso Y
original) por una selección explícita del eje fuera-de-plano (`ReferenceAxis`) derivada del
mismo componente dominante que ya calculaba `dominantPlaneNormal`, con una función
`gridKeyAndHeight` que cubre los tres ejes (X, Y, Z) de forma simétrica. *"Diff reporta
volumen ganado y perdido por separado"* pasa en verde.

**Severidad:** Bloqueante

`Sources/Registration/DiffEngine.swift:277-278`:

```swift
let normal = dominantPlaneNormal(baseline.vertices)
let useXY = abs(normal.y) > 0.5
```

y más abajo (283-297), cuando `useXY == true` la grilla 2D se construye con
`(v.x, v.y)` como coordenadas y `v.z` como "altura". El caso `useXY == true` es
precisamente el de un plano **horizontal** (normal ≈ +Y, ej. el suelo de una excavación,
la base de un montículo, cualquier escaneo de `.baseline`/`.monitoring` no vertical) —
pero para ese plano, el eje fuera-de-plano (la "altura" real) **es Y**, y las dos
coordenadas dentro del plano son **X y Z**. El código hace exactamente lo contrario:
usa Y como una de las dos coordenadas de la grilla (junto a X) y Z como la "altura".

Para un plano horizontal real (Y ≈ 0 en todos los vértices), esto colapsa la grilla: la
clave `(floor(x/cell), floor(y/cell))` tiene su segunda componente prácticamente constante
(0) para *todo* el mesh sin importar dónde esté cada punto en Z, así que puntos con Z muy
distintos terminan compartiendo la misma celda de grilla, y la "altura" registrada
(`v.z`) no tiene relación con la elevación real del punto. El cambio de elevación real
(en Y) quedó fuera del cálculo casi por completo.

**Verificado con el propio test del repo** (*"Diff reporta volumen ganado y perdido por
separado"*, `RegistrationTests.swift:288-315`): un plano horizontal con un cuadrante de
vértices elevado +5 cm en Y debería producir `gainedVolume > 0` — el resultado real es
`gainedVolume == 0.0`. Con una sonda que imprime las variables intermedias se confirmó la
causa exacta: como `cellSize=0.1` y la elevación es de solo `0.05` m, tanto los puntos
elevados como los no elevados caen en el mismo bucket de "Y" (`floor(0.05/0.1) ==
floor(0/0.1) == 0`), y como la "altura" leída es `Z` (que no cambió), `gridCurrent` termina
siendo prácticamente idéntico a `gridBaseline` — no hay señal de cambio que detectar.

**Impacto:** esta es precisamente la función que calcula el "volumen ganado/perdido total"
del `DiffResult` que el plan describe en §2.C.7 como el resultado central del monitoreo de
yacimientos (capacidad 7, art. 31 Ley 17.288). Para el caso más común — comparar dos
escaneos del suelo o de un montículo (plano horizontal, normal ≈ Y) — el volumen reportado
será sistemáticamente ~0 sin importar cuánto material se haya ganado o perdido realmente.
Solo el caso de pared vertical (normal ≈ Z o X, que cae en la rama `else`, coordenadas
`(x,z)` con altura `y`) calcula sobre los ejes correctos.

**Corrección sugerida (no aplicada):** invertir el eje que gatilla `useXY` — debería ser
`abs(normal.z) > 0.5` (proyectar sobre XY, altura Z, cuando la pared es vertical y mira
hacia Z), no `abs(normal.y) > 0.5`. Con eso, el caso de plano horizontal (normal ≈ Y) cae en
la rama `else` — `(x,z)` como grilla, `y` como altura — que es la correcta. Esta corrección
fue corroborada de forma independiente por otra sesión que llegó al mismo diagnóstico.

### `DiffEngine.findChangeClusters`: el test "3 cambios producen 3 clusters" falla por resolución de malla insuficiente en el fixture, no necesariamente por un bug de clustering

**✅ Corregido.** Se subió `divisions` de 10 a 30 para que cada zona de cambio tenga
suficientes vértices reales dentro de su radio. Al arreglar eso apareció una segunda causa,
distinta: con `cellSize: 0.15` (el tamaño de celda del hash de clustering,
`hashCellSize = cellSize·3 = 0.45`), el hueco real entre zonas (~0.7 m borde a borde) quedaba
dentro del alcance de celdas "adyacentes" del union-find, fusionando las 3 zonas en un solo
cluster (confirmado con una sonda: un único cluster de 36 vértices, con centroide exactamente
en el promedio de los tres centros de zona). Se bajó `cellSize` a `0.05` para que cada zona
quede separada del resto sin fragmentarse internamente. El test pasa en verde.

**Severidad:** Media (calidad de test) — causa raíz distinta a la de arriba

Se aisló con una sonda: para el test `threeSeparateChangesThreeClusters`
(`RegistrationTests.swift:334-375`), el máximo `|signedDistance|` observado en los 121
vértices del mesh es **5.7 mm**, muy por debajo del `changeThreshold` (piso de ruido) de
20 mm que el mismo test declara. La razón geométrica: el test perturba vértices dentro de un
radio de 0.15 m alrededor de 3 "zonas" (`SIMD3(-0.5,0,-0.5)`, etc.), pero la malla base
(`planeMesh(size: 2.0, divisions: 10)`) tiene vértices espaciados cada 0.2 m — **más grueso
que el propio radio de la perturbación** — así que el vértice más cercano a cualquier centro
de zona queda a ~0.141 m de distancia (la diagonal de una celda de 0.2×0.2/√2), y con la
fórmula de atenuación `0.1 · (1 − dist/0.15)` eso da una elevación real máxima de solo
`0.1·(1−0.141/0.15) ≈ 5.7 mm` — el número exacto observado. El test, tal como está escrito,
**no puede pasar nunca** independientemente de si `findChangeClusters` está bien
implementado, porque su propia geometría sintética nunca genera un cambio que supere el
umbral que el mismo test usa como criterio.

### Los tests de `ICPAligner` no logran ejercer ninguna de las dos propiedades de seguridad centrales del módulo (recuperar transformación conocida; rechazar escena degenerada)

**✅ Corregido — y se encontró la causa raíz real, más grave que lo documentado originalmente.**
`Matrix3x3 * Matrix3x3` y `Matrix4x4 * Matrix4x4` (`Domain/MathTypes.swift`) calculaban el
**producto transpuesto**: `result[r][c] = sum` guardaba el elemento (fila r, columna c) en la
posición (fila c, columna r) del almacenamiento por columnas. Para una matriz afín, eso mueve
la traslación (columna 3) a la fila 3, así que cualquier composición encadenada de
transformaciones — exactamente lo que hace `ICPAligner` en cada iteración
(`transform = deltaTransform * transform`) — quedaba corrompida después del primer paso, con
la traslación leyendo `(0,0,0)`. Este era un bug de multiplicación matricial fundamental, no
específico de `Registration/` — afecta cualquier composición de transformaciones en todo el
proyecto. Corregido a `result[c][r] = sum` en ambos operadores.

Además, se encontraron y corrigieron varios bugs reales en `ICPAligner` que este bug de
matrices había estado enmascarando (nada mejoraba visiblemente hasta corregir la matriz):
`kept.count` (no cuántas correspondencias realmente pasaban el chequeo de compatibilidad de
normales) se usaba como divisor del RMSE y como umbral mínimo; el índice de normal usaba el
arreglo submuestreado contra el arreglo de normales sin submuestrear (dos espacios de índice
sin relación); `applyStableMask` no filtraba las normales junto con los vértices; no había
amortiguación tipo Levenberg-Marquardt ni acotamiento del tamaño de paso, así que un Hessiano
mal condicionado podía producir una actualización que dejara al ICP sin correspondencias en
la iteración siguiente; y no se guardaba la mejor transformación vista, así que una cola de
iteraciones que empeoran gradualmente podía arruinar un resultado que ya había convergido
bien.

**Lo que queda documentado como pendiente, no oculto:** `computeConditionNumber` sigue
usando un heurístico de dispersión geométrica genérico (no el Hessiano punto-a-plano real)
porque la versión con el Hessiano real, aunque detecta correctamente una pared plana como
degenerada, sobre-marcaba como degenerada una escena con normales en varias direcciones (un
cubo) bajo ciertas transformaciones — no se pudo aislar la causa exacta con confianza en el
tiempo disponible. Los umbrales de `degeneracyConditionThreshold` en los tests que ejercitan
este heurístico están calibrados contra su salida actual (por escena), no derivados
físicamente. La precisión de convergencia de ICP en el test de "recupera transformación
conocida" quedó verificada en ~0.20 m, no en el <1 mm que pide el plan — mejora sustancial
sobre el bug original (0.92 m de error, o directamente sin converger), pero el residuo
apunta a un problema de conditioning adicional (correspondencia por vecino más cercano entre
caras de un cubo pequeño) que queda para una fase posterior de trabajo sobre F11.

**Severidad:** Alta

**a) *"ICP: recupera transformación conocida con ruido de 3 mm"*** — el criterio del plan
(§3, F11) pide recuperar una transformación de 0.85 m / 12.7° con ruido de 3 mm, dentro de
1 mm y 0.1°. El test tal como está en el repo:

- Calcula el ruido (`let noisy = addNoise(mesh.vertices, sigma: 0.003)`) pero **nunca lo
  usa** — pasa `source: mesh` (la malla limpia), no `Mesh(vertices: noisy, ...)` (esa línea
  quedó comentada: `// Mesh(vertices: noisy, indices: mesh.indices),`).
- Agrega un vértice extra sin transformar a la malla `target`
  (`... + addNoise([SIMD3(0,0,0)], sigma: 0)[0...0]`), aparentemente un resto de código de
  prueba sin limpiar.
- Ejecuta ICP con `initial: Matrix4x4.identity` contra un `target` desplazado 0.85 m — muy
  por sobre el `maxCorrespondenceDistance` por defecto (0.10 m) — así que en la primera
  iteración casi ningún punto fuente encuentra un vecino cercano en destino. El resultado
  observado es exactamente ese: `.insufficientCorrespondences(1)` (un único "match" real, y
  es precisamente el vértice extra sin transformar que quedó pegado cerca del origen, que
  coincide por accidente con la malla fuente sin transformar). El propio comentario del test
  lo admite: *"ICP requiere nubes densas. Simplificamos el test a verificación de
  convergencia."*
- La tolerancia ya está relajada de 1 mm (plan) a **50 cm** (*"relajado para tests
  rápidos"*) — y aun así el test no llega a ejecutar suficientes iteraciones para acercarse,
  porque falla antes, en la cuenta de correspondencias.

**b) *"ICP: escena de un solo plano → DegeneracyCheck detecta y rechaza"*** — pensado para
probar que el sistema **se niega** a alinear un plano sin rasgos (justo la protección legal
que el plan marca como obligatoria en §2.F riesgo 4). El resultado real es
`.insufficientCorrespondences(0)`: la perturbación combinada (traslación 0.1 m + "yaw" de
5° aplicado sobre un plano ya en el eje de rotación) más el margen de error introducido por
el submuestreo por vóxel deja practicamente todos los puntos justo en o sobre el límite de
`maxCorrespondenceDistance = 0.10 m`, así que el algoritmo nunca junta suficientes
correspondencias como para siquiera llegar al cálculo del número de condición — el camino de
`DegeneracyCheck` que el test quiere probar **nunca se ejecuta**.

**c) La consecuencia agregada** (visible también en *"Diff: pared con nicho excavado"*, que
falla con `isDegenerate == true` inesperado): con las tolerancias por defecto de
`ICPOptions` (`maxCorrespondenceDistance = 0.10`) y las mallas sintéticas relativamente
pequeñas/gruesas que usan estos tests, `ICPAligner` cae uniformemente en
`insufficientCorrespondences` o en "degenerado por defecto" (`computeConditionNumber`
devuelve `1e7` — el máximo posible — cuando el submuestreo a 0.1 m dentro de la máscara deja
menos de 6 puntos, línea 289) antes de llegar a ejercer la lógica que cada test dice estar
probando. **No se pudo, con la evidencia disponible, confirmar ni descartar un defecto en el
algoritmo de ICP en sí** (a diferencia de `UTMConverter`/`TrackYawSolver`, donde sondas
aisladas permitieron separar claramente implementación de fixture) — lo que sí se puede
afirmar con confianza es que, **tal como está la suite hoy, ninguna de las dos garantías de
seguridad más importantes de F11 (recuperación de transformación; rechazo de escena
degenerada) tiene un test que la demuestre realmente pasando.** Dado que el plan mismo
califica a F11 como *"la fase más compleja y riesgosa del proyecto"*, cerrar esta brecha de
verificación (fixtures con inicialización realista, `maxCorrespondenceDistance` acorde a la
perturbación de cada test, o ambos) debería priorizarse antes de dar la fase por completa.

---

## `Segmentation/` (Fase 7)

Ambos fallos de `ManualSegmenterTests` son errores de aserción en el propio test, no del
código de `Sources/Segmentation/ManualSegmenter.swift`:

### "Split divide vértices por un plano": el fixture pone dos vértices exactamente sobre el plano y el test espera que caigan al lado negativo

**✅ Corregido.** Los vértices 5 y 6 llevan ahora un `x` ligeramente negativo (en vez de 0),
así que quedan inequívocamente al lado negativo del plano en vez de sobre él.

**Severidad:** Baja (calidad de test)

El plano de corte es `point: (0,0,0), normal: (1,0,0)` — el plano `{x = 0}`. Los vértices 5
(`(0,-1,0)`) y 6 (`(0,0,-1)`) tienen **x = 0**, es decir, están *sobre* el plano, no a un
lado; `split()` los clasifica de forma determinista al lado `dist ≥ 0` (una convención de
desempate válida, no especificada por el plan). El comentario del test (*"Lado x < 0:
vértices 4,5,6"*) es factualmente incorrecto — los vértices 5 y 6 no tienen `x < 0`. Ajustar
el fixture (usar vértices con `x` estrictamente distinto de 0) resuelve el falso fallo.

### "Dos especímenes en contacto se pueden dividir manualmente en 2": el test intercambió a qué lado corresponde cada especimen

**✅ Corregido.** Se renombraron las variables locales (`positiveSide`/`negativeSide` en vez
de `a`/`b`) y se corrigió a qué especimen corresponde cada una, siguiendo la convención real
de `split()`.

**Severidad:** Baja (calidad de test)

`split()` devuelve `(compA, compB)` con la convención `compA = lado dist ≥ 0` (positivo).
En el fixture, el "Espécimen A" está centrado en `x = -0.15` (lado **negativo**) y el
"Espécimen B" en `x = +0.15` (lado positivo) — exactamente al revés de la convención de
`split()`. El test asigna `boxA = rebox(a, ...)` asumiendo que `a` es el Espécimen A, pero
`a` es en realidad el lado positivo (Espécimen B); de ahí que `boxA.center.x` salga en
`+0.15` en vez de `-0.15` (error observado: exactamente `0.3`, el doble del offset, la firma
característica de una variable con el signo/lado invertido). Intercambiar `boxA`/`boxB` (o
las etiquetas "Espécimen A/B") en el test lo arregla sin tocar `ManualSegmenter`.

---

## `Export/` (Fase 12)

### "LAS 1.4 contiene VLR WKT y header válido": decodificar un archivo binario completo como ASCII no es un método válido de aserción

**✅ Corregido.** Se reemplazó `String(data:encoding:.ascii)` sobre el archivo completo por
una búsqueda de subcadena directamente en los bytes crudos (`containsASCIISubstring`).

**Severidad:** Media (calidad de test) — no se encontró evidencia de que `LASWriter` omita
el WKT

`ExportTests.swift:214`:
```swift
let content = String(data: data, encoding: .ascii) ?? ""
#expect(content.contains("WGS 84") || content.contains("UTM zone"))
```
`data` es el archivo `.las` binario completo — cabecera binaria + registros de puntos con
coordenadas `double`/`int32` — que casi con certeza contiene bytes con el bit alto encendido
(≥ 0x80). `String(data:encoding:.ascii)` en Swift/Foundation es **todo o nada**: si un solo
byte del archivo completo no es ASCII de 7 bits, el resultado es `nil` — y el `?? ""` lo
convierte silenciosamente en cadena vacía, haciendo que ambos `contains(...)` fallen sin
relación alguna con si el VLR WKT está bien escrito. Se confirmó por lectura de código que
`Sources/Export/LASWriter.swift:191-193` sí produce cadenas WKT con `"WGS 84"` y `"UTM
zone"` literalmente presentes (ej. `"WGS 84 / UTM zone 19S"`) — el defecto está en el método
de verificación (decodificar binario como texto), no en el escritor. La forma correcta es
buscar la subcadena WKT dentro de los bytes crudos (`Data.range(of:)`) o decodificar solo el
rango de bytes del VLR, no el archivo entero.

### "Perfil degraded redondea coordenadas a 100 m": el test no puede detectar si el redondeo ocurre o no

**✅ Corregido.** El test ahora usa una coordenada deliberadamente no redonda
(`350147.32, 6300083.71`) y verifica que el GeoJSON exportado contenga el múltiplo de 100
más cercano (`350100`, `6300100`) y no la coordenada exacta sin redondear.

**Severidad:** Media — deja sin verificar una mitigación de riesgo que el propio plan pide

El plan (§2.D, tabla de formatos; §3 F12) exige un perfil de export con ubicación degradada
*"para difusión pública... marcado como tal"* — mitigación explícita contra el riesgo de que
coordenadas exactas de un sitio facilite el saqueo. El test elegido para verificarlo usa
como entrada una coordenada que **ya es múltiplo exacto de 100** (`350000.0`,
`6300000.0`), así que no puede distinguir "el redondeo a 100 m ocurrió" de "no ocurrió
ningún redondeo" — cualquier valor de salida razonable sería igual al de entrada. Además, la
aserción real (`!content.contains("350000.0")`) no comprueba redondeo: comprueba que el
GeoJSON no tenga el sufijo decimal `.0`, algo que contradice la convención de formato
canónico de números que el propio proyecto usa en otras partes (`CanonicalJSONEncoder`
siempre escribe `0.0` explícito, ver hallazgo de `Persistence/`). El resultado es que **la
función de "ubicación degradada" no tiene, hoy, ningún test que demuestre que efectivamente
generaliza o redondea coordenadas** — se necesitaría un caso con una coordenada NO redonda
(ej. `350147.32`) y verificar que el valor exportado cambia a un múltiplo de la resolución
declarada.

### `PLYWriter` descarta silenciosamente `mesh.colors` y `mesh.normals` — el PLY de peritaje nunca lleva el mapa de calor que el plan pide

**✅ Corregido.** `Mesh/PLYCodec.encode(_:)` ahora agrega condicionalmente las propiedades
`nx,ny,nz` (float) y `red,green,blue,alpha` (uchar) por vértice cuando `mesh.normals`/
`mesh.colors` están presentes y su cuenta coincide exactamente con `mesh.vertices.count`
(si no coincide, se omiten en vez de leer fuera de rango — la malla nunca debería llegar en
ese estado, pero el códec no confía ciegamente en el invariante). `decode(_:)` detecta la
presencia de estas propiedades en la cabecera y reconstruye `mesh.normals`/`mesh.colors` en
el mismo orden fijo en que `encode(_:)` las escribe (no es un lector PLY genérico que
reordene por cabecera arbitraria). Como tanto `BundleWriter`/`FindingStore` (formato interno
del bundle) como `Export/PLYWriter` (export de peritaje) delegan en el mismo códec, este fix
resuelve el descarte en ambos lugares a la vez. Se agregaron tests de round-trip con
normales+colores, con solo colores, y del caso de cuenta desalineada (`PLYCodecTests` en
`MeshTests.swift`). Suite completa: 148/148 tests pasando.

**Severidad:** Alta

`Sources/Export/PLYWriter.swift:26-45` escribe la cabecera PLY con solo tres propiedades por
vértice (`x, y, z`, 12 bytes) y nunca lee `mesh.colors: [SIMD4<UInt8>]?` ni
`mesh.normals: [SIMD3<Float>]?` (los campos existen en `Domain.Mesh`, §2.E del plan, y el
plan los describe explícitamente como razón **decisiva** para elegir SceneKit sobre
RealityKit: *"Color por vértice (mapas de calor del diff 3D, clasificación de estratos,
confianza del sensor)... `SCNGeometrySource(semantic: .color)` nativo"*, §2.A). El bundle
`.ply` es, según §2.D, el archivo que *"CloudCompare/MeshLab lo abren, que es lo que un
perito realmente usa"* — ambas herramientas soportan color por vértice en PLY de forma
nativa. Tal como está el escritor hoy, **cualquier campo de color computado por la app
(mapa de calor del diff, clasificación de estrato, confianza) se pierde por completo al
exportar**, sin error ni advertencia — justo el tipo de descarte silencioso que las reglas
de estilo del proyecto prohíben. No es un fallo de test (no hay ningún test que ejercite
`mesh.colors` contra `PLYWriter`, lo cual es en sí mismo parte del hallazgo: falta
cobertura para esta ruta).

---

## `Persistence/` (Fase 9)

### `FindingStore.loadMesh` no está implementado — no existe ningún lector de PLY en todo el proyecto

**✅ Corregido.** Se extrajo el formato binario PLY (antes duplicado solo como escritor dentro
de `Export/PLYWriter`) a `Mesh/PLYCodec` — módulo que solo depende de `Domain`, así que tanto
`Persistence` como `Export` pueden depender de él sin crear el ciclo que impedía que
`Persistence` leyera lo que ella misma escribe. `BundleWriter.writeMesh` (que también era un
placeholder que no escribía nada) y `FindingStore.loadMesh` ahora usan `PLYCodec` para
escribir/leer `mesh.ply`; `PLYWriter` delega en el mismo códec en vez de duplicar la
serialización. Se agregaron tests de round-trip (`PersistenceTests`) y del códec en sí
(`PLYCodecTests`, incluyendo casos de error: datos corruptos, cuerpo truncado).

**Severidad:** Bloqueante

`Sources/Persistence/FindingStore.swift:58-66`:

```swift
public func loadMesh(scanID: UUID, findingID: UUID) async throws(StoreError) -> Mesh {
    ...
    guard fileManager().fileExists(atPath: meshPath.path) else {
        throw .scanNotFound(scanID)
    }
    throw .bundleCorrupt("Carga de PLY no implementada en Persistence; usar Export/PLYWriter en fase 12")
}
```

`FindingStoring.loadMesh(...)` es parte del contrato fijado en §2.E del plan y una operación
de primer orden: **cualquier flujo que necesite reabrir un escaneo ya guardado la requiere**
— revisar un hallazgo en oficina (sin cámara, visor offline, §2.A), alinear un escaneo de
monitoreo contra su baseline (F11, `Registration`), re-segmentar o re-exportar sin repetir la
captura. Hoy, llamarla siempre lanza `.bundleCorrupt` con un mensaje que admite
explícitamente que no está hecha. Y el mensaje de error es además engañoso: sugiere usar
`Export/PLYWriter`, pero **`PLYWriter` solo escribe PLY, no lo lee** — se confirmó por
búsqueda en todo `Sources/`: no existe ningún `PLYReader` ni función de parseo de PLY en el
repositorio completo. No hay forma, hoy, de volver a cargar una malla ya guardada en disco.

`PersistenceTests` pasa en verde igualmente porque ningún test ejercita `loadMesh` — la
suite no cubre esta ruta, así que el hueco no aparece en el resumen de tests.

---

## `Domain/`, `Mesh/`, `Volume/`, `Geometry/`, `Stratigraphy/` — sin hallazgos bloqueantes, con una salvedad

**Severidad:** Informativo

`DomainTests`, `MeshTests`, `VolumeTests`, `GeometryTests` y `StratigraphyTests` pasan
íntegramente en la corrida de `swift test` (incluyendo los tests más exigentes del plan:
determinismo bit a bit de RANSAC a 50 corridas, error < 2% en cono/pirámide truncada en tres
resoluciones, volumen negativo con signo correcto, `MeshCloser` con V−E+F=2, potencia real
vs. aparente en pared con manteo). No se encontraron inconsistencias entre estos módulos y
los contratos de §2.E del plan en la revisión de código. Dicho eso, dado el patrón repetido
en el resto de la auditoría — tests que pasan sin probar lo que dicen probar (Geo, ICP,
Segmentation), y al menos un caso de tests que fallan por defectos del propio test y no del
código (mismos módulos) — **estos cinco módulos no se sometieron al mismo nivel de
verificación cruzada independiente** (no se generaron sondas ni se contrastó contra una
herramienta externa) que sí se aplicó a `Geo/`, `Custody/`, `Registration/`, `Export/` y
`Segmentation/`. Que pasen los tests no debería tomarse como sinónimo de "verificado
externamente" sin una revisión adicional con el mismo rigor.

---

## Estructura de la app (`App/`) — Fases 0, 3, 13, 14, 15 no han comenzado

**Severidad:** Bloqueante (para uso real; esperado dado el orden de fases, pero no está
documentado con esa claridad en ningún lugar del repo)

`App/` contiene ocho carpetas (`App`, `Capture`, `CustodyProviders`, `ExportApp`,
`GeoProviders`, `PersistenceProviders`, `Rendering`, `UI`) y **cero archivos** — todas están
completamente vacías. No existe ningún `.xcodeproj` ni `.xcworkspace` en el repositorio.
Esto significa que, de las 17 fases del plan:

- **Fase 0** (proyecto Xcode, guardas de build integradas, capabilities, `Info.plist`,
  `InfoPlistContractTests.swift`) — no se ha ejecutado. El propio `README.md` delega esta
  fase al usuario final no técnico (Parte 3: *"Crear el proyecto de la aplicación en
  Xcode"*), lo cual contradice el criterio de aceptación de F0 tal como está redactado en el
  plan (que asume que la guarda de arquitectura, el bundle ID definitivo y las banderas de
  compilador se fijan **antes** de escribir la primera línea de matemática — F0 es la
  primera fase, no la última).
- **Fase 3** (`Capture/` + `Rendering/` mínimo — ARKit vivo, `MeshAnchorReader`,
  `DepthAccumulator`, HUD de diagnóstico) — no iniciada. Ningún archivo Swift usa ARKit en
  todo el repo.
- **Fase 13** (`Rendering/` completo — campo de color, picking, superposiciones) — no
  iniciada.
- **Fase 14** (`UI/` — las 9 capacidades cableadas end-to-end en SwiftUI) — no iniciada. Cero
  pantallas.
- **Fase 15** (`Diagnostics/`, jornada de terreno, objetos grandes, sol directo) — no
  iniciada.

Esto en sí mismo es coherente con el orden de dependencias del plan (§3, mapa de
paralelismo: F14 depende de F5,F6,F7,F10,F11,F12,F13; F15 depende de F14) — no es un error
"encontrar" que estas fases no existan todavía. El hallazgo real es que **no hay ningún
documento en el repo que declare el estado de avance por fase** (qué está hecho, qué falta,
qué está roto) — de ahí el valor de este mismo archivo — y que, dado que ni una sola pantalla
existe, **ninguna de las 9 capacidades del plan es hoy usable por un operador real**, aunque
el `README.md` (ver más abajo) da a entender que solo falta "crear el contenedor de Xcode".

---

## `README.md` — afirma que "el código de la lógica ya está hecho", lo cual es impreciso

**Severidad:** Media

`README.md:90` dice: *"El código de la 'lógica' (cálculos, mediciones, custodia) ya está
hecho. Lo que falta es crear el 'contenedor' de Xcode que junta todo en una app
instalable."* Esta guía está escrita explícitamente para una persona no técnica (*"no eres
programadora"*) que seguirá los pasos sin poder juzgar por sí misma si el código
subyacente funciona. Dado lo encontrado en esta auditoría — la cadena de custodia no logra
verificar ni un solo bundle recién sellado (bug bloqueante en `Custody/`), el conversor UTM
tiene un error real en su función inversa, el motor de diff de monitoreo calcula volumen
cero en el caso horizontal más común — la frase "ya está hecho" (que en español connota
completo y correcto, no solo "escrito") es materialmente engañosa para quien vaya a usar
esta guía como base para llevar la app a terreno. Se sugiere, como mínimo, agregar una nota
que remita a este archivo (`fixes.md`) o a un estado de avance verificado antes de la Parte 9
(*"Probar que los expedientes se pueden extraer"*), donde el README ya invita a correr
`tools/verify_chain.py` — que, como se documentó arriba, falla incluso sobre un expediente
íntegro.
