# Plan LiDAR Paleontológico/Arqueológico — app iOS nueva ("PaleoRegistro")

## Cómo usar este documento

Este plan **es** el encargo técnico para construir, desde cero absoluto, una app iOS nueva
que usa el sensor LiDAR del iPhone para el registro de hallazgos paleontológicos y
arqueológicos en Chile, bajo el marco de la Ley 17.288 (Consejo de Monumentos Nacionales —
CMN — y Museo Nacional de Historia Natural — MNHN). Está pensado para que cualquier sesión
de LLM, sin contexto previo del proyecto, pueda tomar una fase, ejecutarla y producir una
pieza compatible con el resto.

**No es un fork ni depende del repositorio `stockia_apple`.** Es un proyecto Xcode nuevo,
con su propio bundle ID. Lo que se reutiliza de `stockia_apple` (app hermana de medición de
volumen de áridos con LiDAR) es **conocimiento algorítmico**: su pipeline de plano de suelo
por RANSAC y su integrador de volumen por grilla de elevación son un punto de partida sólido
y ya probado, que aquí se generaliza (plano con restricción de orientación, volumen positivo
y negativo, multi-objeto, georreferenciación, cadena de custodia). Cada vez que este
documento reutiliza una idea de ese repo, cita el archivo exacto.

Orden de lectura recomendado: alcance (§1) → arquitectura (§2) → fases de ejecución (§3) →
checklist de Xcode (§4) → estimación y riesgos (§5) → información faltante (§6).

---

## 1. Alcance

**Objetivo observable:** un jefe de obra, paleontólogo o arqueólogo en terreno, sin
conexión a internet, puede capturar con el iPhone un registro 3D métrico y
georreferenciado de un hallazgo, suficiente como insumo técnico y legal para el aviso al
CMN dentro del plazo de 5 días hábiles y para el informe de rescate posterior, sin depender
de ningún servidor.

### En alcance (v1)

Las 9 capacidades siguientes, **todas con la misma prioridad de producto** — no hay una
"fase 2 opcional" entre ellas. La única jerarquía que existe en este documento es de
**dependencia técnica** (qué módulo necesita que otro exista primero), explicada en §3.

1. Registro 3D del hallazgo imprevisto en obra (malla + escala + coordenadas, antes de la
   llegada del CMN).
2. Perfiles estratigráficos de la pared del corte (potencia del nivel fosilífero, manteo).
3. Georreferenciación UTM/WGS84 de cada escaneo vía GPS del iPhone.
4. Cadena de custodia: sellado con fecha/hora/GPS antes y después de cualquier intervención.
5. Cuantificación de daños por maquinaria (volumen/material perdido).
6. Documentación del rescate paleontológico completo (multi-especimen: posición,
   orientación, asociación espacial).
7. Monitoreo periódico de yacimientos/santuarios (art. 31): diff 3D entre campañas.
8. Réplicas 3D para museografía (export apto para impresión, sin tocar el original).
9. Inventario volumétrico de fósiles grandes (dimensiones/volumen para extracción,
   transporte y embalaje).

Todas comparten: captura LiDAR en terreno, export de archivos locales (OBJ/PLY/STL/LAS +
metadata JSON + PDF), sellado de integridad, sin backend.

### Fuera de alcance (v1)

- Backend/nube, sincronización multiusuario, cuentas de usuario con roles remotos.
- Generación automática y envío del informe final al CMN (la app produce los **insumos**:
  modelo 3D, mediciones, coordenadas, PDF de respaldo — no gestiona el trámite).
- Reconocimiento automático de especies o clasificación taxonómica.
- Impresión 3D en sí misma (solo exportación del archivo para imprimir).
- Integración con los sistemas internos del MNHN.
- Firma electrónica avanzada (FEA) conforme a la normativa chilena de documento
  electrónico, y sellado de tiempo por autoridad certificadora (TSA) — ver §6, punto 4.
- Autenticación de usuarios/roles dentro de la app.

### Supuestos

- Los artículos de ley citados por el usuario (26, 31, 38 de la Ley 17.288) y el plazo de
  aviso de 5 días hábiles al CMN se toman como dados y se traducen directamente en
  requisitos funcionales. Este documento no audita el texto legal.
- El MNHN es el destino legal de las colecciones paleontológicas; de ahí que las réplicas
  (capacidad 8) existan para exhibición sin mover el original.
- App nueva, un solo operador por dispositivo, sin conectividad garantizada en terreno.

---

## 2. Arquitectura técnica

### 2.A Decisión tecnológica: ARKit + SceneKit, con el renderer aislado tras un protocolo

**Recomendación: ARKit como fuente de verdad + SceneKit como capa de presentación, con la
regla arquitectónica de que ningún tipo de dominio importe SceneKit.**

Justificación por requisito real de este caso de uso:

| Requisito | SceneKit | RealityKit | Peso |
|---|---|---|---|
| Picking interactivo sobre malla reconstruida (puntos de suelo, semillas de espécimen, límites de estrato en la pared) | `SCNView.hitTest` funciona directo sobre geometría arbitraria | Requiere `CollisionComponent`; `generateCollisionShapes` sobre mallas de 300k-1M triángulos es caro y aproxima por convex hull → inservible para picking preciso sobre superficie cóncava | **Decisivo** |
| Color por vértice (mapas de calor del diff 3D, clasificación de estratos, confianza del sensor) | `SCNGeometrySource(semantic: .color)` nativo | Requiere `CustomMaterial` con shader Metal propio | Alto |
| Visor offline sin cámara (revisar escaneos guardados en oficina) | `SCNView` autónomo, trivial | `ARView` en `.nonAR` es más pesado y menos ergonómico | Alto |
| Sesiones largas en exterior, presupuesto térmico | Overlay wireframe barato, control fino del pipeline de render | PBR + IBL por defecto, mayor consumo sostenido | Alto |
| Exportación a formatos estándar | Irrelevante (serializadores propios) | Irrelevante | Nulo |
| Longevidad de API | Obsolescencia anunciada por Apple | Camino oficial | Riesgo |

El único argumento fuerte a favor de RealityKit es su longevidad. Se mitiga
arquitectónicamente: **`Rendering/` es el único módulo que importa SceneKit**, expone un
protocolo `ScanRendering` y consume solo tipos de dominio (`Mesh`, `Plane`, `OrientedBox`).
Migrar a RealityKit el día de mañana es reescribir una carpeta hoja, no el pipeline. La
exportación no depende del motor de render (ModelIO para USDZ, serializadores propios para
PLY/STL/OBJ/LAS), así que esa dependencia no contamina el artefacto legal.

**Configuración de captura fijada desde el día 1:**

- `ARWorldTrackingConfiguration.sceneReconstruction = .meshWithClassification`. La
  clasificación (`floor`, `wall`, `none`) se usa como **prior** para sembrar el RANSAC de
  suelo (volumen) y el de pared (estratigrafía), reduciendo iteraciones y evitando que el
  plano dominante equivocado gane el consenso. Fallback a `.mesh` si el dispositivo no la
  soporta.
- `frameSemantics = [.sceneDepth, .smoothedSceneDepth]`. La malla de `ARMeshAnchor` tiene
  triángulos de ~5-10 cm y está suavizada; para mediciones finas (potencia de estrato,
  cavidad de daño) hace falta una nube densa propia derivada de `sceneDepth` +
  `confidenceMap`. **Ambas rutas conviven**: `ARMeshAnchor` para el modelo geométrico
  general, `sceneDepth` acumulado para las mediciones críticas.
- `worldAlignment = .gravity`, **no** `.gravityAndHeading`. La brújula cerca de maquinaria
  pesada o roca con magnetita (frecuente en Chile) tiene errores de 10-30°. El yaw hacia el
  norte verdadero se resuelve a posteriori alineando la trayectoria AR contra la traza GPS
  (módulo `Geo/TrackYawSolver`); el heading magnético se guarda solo como control cruzado.
- `ARGeoTrackingConfiguration` queda descartado: la cobertura VPS de Apple no incluye Chile.
- `ARWorldMap` se persiste por escaneo (útil para relocalizar el mismo día en el par
  baseline/post-intervención), pero **no** es el mecanismo de registro multitemporal: en
  exterior, a meses vista, la relocalización falla por vegetación, iluminación y estación.

### 2.B Modelo de datos

**Jerarquía:**

```
Site (yacimiento / punto de obra)
 └── Finding (hallazgo: el expediente legal)
      ├── ScanSession × N   (baseline, post-intervención, monitoreo, daño, rescate)
      │    ├── Specimen × M (piezas segmentadas dentro del escaneo)
      │    ├── Measurement × K (volumen ±, potencia, distancia, dimensiones)
      │    ├── StratigraphicProfile × P
      │    └── MediaAsset × Q (fotos, orto-imagen rectificada)
      ├── Comparison × C   (diff entre dos ScanSession)
      └── CustodyChain     (cadena de sellos, append-only)
```

**`Site`** es la entidad que hace posible el monitoreo (art. 31): agrupa escaneos de
distintas fechas y define el **marco de sitio** (`SiteFrame`) canónico, establecido por el
escaneo baseline. Todo escaneo posterior guarda `siteAlignment: simd_float4x4` (su marco AR
local → marco de sitio). Sin `Site` como entidad de primer nivel, el diff multitemporal no
tiene dónde anclarse.

**`ScanSession`** tiene `purpose: ScanPurpose` (`.baseline`, `.postIntervention`,
`.monitoring`, `.damageAssessment`, `.rescueDocumentation`, `.specimenInventory`,
`.stratigraphicProfile`). El propósito determina el pipeline de procesamiento aplicado
(política, no ramas ad-hoc en la UI).

**Versionado/linaje**: `ScanSession` tiene `parentScanID: UUID?` y `supersedes: UUID?`. Los
escaneos forman un DAG con raíz en el baseline del sitio. `supersedes` cubre "el escaneo
salió mal y se repitió": **nunca se edita ni borra un escaneo sellado**; se crea uno nuevo
que declara al anterior superado. La inmutabilidad de la evidencia es la regla.

**`Specimen`** no duplica geometría completa: guarda `vertexIndices: [UInt32]` (subconjunto
de la malla del escaneo) **o** un archivo `.ply` propio cuando es un escaneo dedicado, más
`pose: OrientedBox` en el marco de sitio. Las relaciones espaciales entre especímenes
(`SpecimenRelation`: distancia centro-centro, azimut, contacto/solapamiento, diferencia de
cota) son **derivadas** de las `OrientedBox`, no almacenadas redundantemente, salvo las
anotadas manualmente por el paleontólogo (`associationNote`).

**Volumen expuesto vs. total**: para restos grandes parcialmente enterrados, `Specimen`
distingue `exposedVolume` (medido) de `estimatedTotalVolume` (inferido, con método y
supuestos registrados). Confundirlos arruina la planificación de extracción y expone
legalmente el informe.

**Persistencia — bundle de archivos como fuente de verdad, base de datos solo como índice:**

```
Documents/Findings/FND-2026-0412-9f3a/
  finding.json               manifiesto versionado (schemaVersion, site, autor, permisos CMN)
  seals/chain.jsonl          cadena de sellos append-only (una línea = un sello)
  scans/<scanID>/
    mesh.ply                 binario little-endian, orden de vértices determinista
    depth/cloud.bin          nube densa opcional (posición + confianza)
    scan.json                metadata de captura + parámetros de algoritmo + semilla RNG
    measurements.json
    specimens/<id>.ply
    media/<id>.heic + <id>.json (pose de cámara, intrínsecos, timestamp)
    worldmap.arworldmap      opcional
    .sealed                  marcador; tras el sello el directorio es de solo lectura
  comparisons/<id>.json
  exports/
```

**Decisión clave: el bundle en disco es el registro legal; SwiftData es un índice derivado
y reconstruible.** Razones: (1) hashear una base SQLite es inútil como evidencia, (2) el
perito necesita una carpeta autocontenida que pueda copiar y verificar con herramientas
externas, (3) el índice puede corromperse o migrarse sin poner en riesgo la evidencia. El
índice guarda solo lo consultable (id, fecha, sitio, UTM, thumbnails, estado de sello) para
que la lista de hallazgos y el mapa carguen sin abrir cientos de mallas.

Todo el JSON se serializa con un **encoder canónico** (claves ordenadas, sin espacios,
floats con representación decimal fija) para que el hash sea reproducible.

### 2.C Arquitectura de módulos

```
PaleoRegistro/
  App/              entrypoint, contenedor de dependencias, routing, Trace (os_signpost)
  Domain/           tipos puros, cero imports de framework: Mesh, Plane, OrientedBox, GeoFix,
                    UTMCoordinate, SiteFrame, Finding, ScanSession, Specimen, Measurement,
                    VolumeResult, DiffResult, SealRecord, QualityReport, errores tipados
  Capture/          ARKit: ARSessionManager, MeshAnchorReader, DepthAccumulator,
                    CoverageTracker, CaptureGuidance, PhotoCapture, ControlTargetDetector
  Mesh/             MeshMergeCore, ROIFilter, MeshOps (normales, componentes conexas,
                    decimación por vóxel, reparación de orientación), MeshCloser
  Geometry/         PlaneFitter (LS + RANSAC/MSAC genérico con restricciones), OBBFitter (PCA),
                    Slicer, TriangleSpatialHash, Rectifier (orto-imagen sobre plano)
  Volume/           SignedHeightFieldIntegrator, ClosedMeshIntegrator, CavityIntegrator,
                    ReferenceSurfaceBuilder, VolumePolicy
  Stratigraphy/     WallProfileBuilder, StratumBoundaryPicker, ThicknessCalculator
  Segmentation/     PlaneRemoval, ConnectedComponentSegmenter, SeedGrowSegmenter,
                    ManualBoxSegmenter, SpecimenExtractor, SpatialRelationBuilder
  Geo/              LocationProvider, FixQualityGate, UTMConverter (Krüger), MeridianConvergence,
                    TrackYawSolver, SiteFrameResolver
  Registration/     CoarseAligner (geo + gravedad + landmarks + targets), ICPAligner,
                    DegeneracyCheck, DiffEngine
  Custody/          CanonicalJSONEncoder, ContentHasher, SecureEnclaveSigner, SealChain,
                    ChainVerifier, TimeAttestation
  Persistence/      FindingStore, BundleLayout, AtomicWriter, FindingIndex (SwiftData), Migrations
  Export/           PLYWriter, STLWriter, OBJWriter, USDZExporter (ModelIO), LASWriter,
                    GeoJSONWriter, ReportPDFRenderer, MetadataSidecarBuilder, ExportBundler
  Rendering/        único módulo que importa SceneKit
  UI/               pantallas SwiftUI por flujo
  Diagnostics/      Trace, QualityReport builder, thermal/disk monitors
```

#### C.1 `Geometry/PlaneFitter` — generalización del estimador de StockIA

El `RANSACPlaneEstimator` actual (`StockIA/Mesh/GroundPlaneEstimator.swift`) sirve tal cual
como núcleo, pero necesita tres cambios estructurales:

1. **Restricción de orientación como parámetro dentro del bucle, no como validación
   posterior.** Hoy `ScanProcessor.swift` valida `abs(plane.normal.y) >= 0.5` *después* del
   ajuste. Para la pared de corte se necesita lo inverso (`abs(normal.y) <= tolerancia`), y
   para paredes en yacimientos con varias caras, "casi perpendicular a una dirección
   conocida". Se resuelve con `OrientationConstraint` aplicado **dentro** del bucle de
   RANSAC: los candidatos que violan la restricción se descartan antes de contar inliers.
   Esto es lo que hace que el plano vertical dominante gane el consenso incluso cuando el
   suelo tiene más puntos que la pared — algo que un RANSAC sin restricción resolvería
   siempre a favor del suelo.
2. **RNG con semilla determinista.** El código actual usa `SystemRandomNumberGenerator`:
   reprocesar el mismo escaneo da un plano ligeramente distinto y por tanto un volumen
   distinto. Para evidencia legal eso es inaceptable. Se reemplaza por un PRNG propio
   (SplitMix64/Xoshiro256++) sembrado con un valor almacenado en `scan.json`. Recomputar el
   resultado desde el bundle debe dar el mismo número, bit a bit.
3. **Puntuación MSAC + prefiltrado por normal + iteraciones adaptativas.** Puntuar con error
   cuadrático truncado en lugar de conteo binario mejora el refinamiento; prefiltrar los
   puntos candidatos por normal de cara (usando la clasificación de ARKit y las normales de
   la malla) acelera la convergencia en órdenes de magnitud; el número de iteraciones se
   calcula adaptativamente `N = log(1-p)/log(1-w³)` con tope, y se registra el N efectivo en
   la metadata.

#### C.2 `Volume/` — volumen positivo, negativo y de sólido cerrado

Tres integradores con una política que elige según el caso:

- **`SignedHeightFieldIntegrator`** — generalización directa de `GridElevationVolumeIntegrator`
  (`StockIA/Volume/VolumeIntegrator.swift`). En vez de una sola grilla con `max(0, h)`,
  mantiene **dos envolventes por celda**: `upper` (máxima altura positiva) y `lower` (mínima
  altura negativa). Devuelve `VolumeResult(positive, negative, net, coveredArea,
  filledCellRatio, uncertainty)`. El `fillInteriorHoles` se generaliza para operar sobre cada
  envolvente por separado. Cubre: montículo sobre plano, zanja/excavación bajo plano, y
  balance neto en monitoreo.
- **`ClosedMeshIntegrator`** — teorema de la divergencia sobre malla cerrada:
  `V = (1/6)·Σ (v0 × v1)·v2`. Es el único correcto para fósiles grandes con **socavaciones y
  voladizos** (un cráneo de ballena o un colmillo de mastodonte no es un campo de alturas
  2.5D; el integrador de StockIA lo subestimaría sistemáticamente). Requiere `MeshCloser`
  (tapado contra el plano de apoyo + relleno de huecos) y publica un diagnóstico de
  estanqueidad (`watertightness`, aristas de borde) que la UI debe mostrar: si la malla no es
  cerrable con confianza, el resultado se marca como estimación.
- **`CavityIntegrator`** — cuantificación de daño. El problema real no es "volumen bajo un
  plano" sino "volumen faltante respecto de la superficie original", y esa superficie no
  existe. Estrategias ordenadas por preferencia:
  1. **Diff contra escaneo previo de la pieza intacta** (si existe): medición, no
     inferencia. Es la razón por la que el registro preventivo (capacidad 1) tiene valor
     probatorio para la capacidad 5.
  2. **Superficie de referencia ajustada al anillo intacto** que rodea el daño: plano o
     cuádrica bicuadrática ajustada por mínimos cuadrados robustos a la corona de superficie
     sana, extrapolada sobre el hueco.
  3. **Completado por simetría** para piezas bilateralmente simétricas: reflejar el lado
     sano sobre el plano de simetría ajustado.

  El `VolumeResult` lleva `method` e `isInferred: true` en los casos 2 y 3. Presentar una
  inferencia como medición es el mayor riesgo legal de este módulo.

#### C.3 `Stratigraphy/` — la potencia no se mide con geometría sola

Decisión de arquitectura que cambia el diseño: **los límites de estrato son transiciones
cromáticas y de textura, no discontinuidades geométricas**. El LiDAR no ve un cambio de
nivel entre dos arcillas de igual dureza. El flujo es:

1. `PlaneFitter` con `OrientationConstraint.vertical` obtiene el plano de la pared de corte
   (aprovechando la clasificación `wall` de ARKit como prior).
2. `Geometry/Rectifier` genera una **orto-imagen métrica**: se proyectan los frames de
   cámara sobre el plano de pared usando intrínsecos + pose de `ARFrame`, produciendo una
   imagen rectificada con escala conocida (px/m). Se elige el frame con mejor ángulo de
   incidencia y foco por región.
3. El operador marca los límites de nivel **sobre la orto-imagen rectificada**, no sobre la
   malla. Cada marca se retro-proyecta al plano y produce una `StratumBoundary` con
   posición 3D.
4. `ThicknessCalculator` mide la potencia como distancia entre límites consecutivos **a lo
   largo del vector de máxima pendiente del plano** (no la distancia euclidiana entre puntos
   marcados, que sobreestima si el operador marcó puntos desplazados lateralmente en un
   contacto inclinado). Reporta espesor verdadero y espesor aparente, más el buzamiento/
   dirección de buzamiento (`dip`/`dipDirection`) derivados de la normal del plano en marco
   de sitio — datos que salen gratis del plano ajustado.
5. La incertidumbre de la potencia se propaga: ruido del plano (RMS de inliers) + error de
   retro-proyección + resolución de la orto-imagen. Si el espesor cae bajo el umbral de
   confianza, la UI exige documentación fotográfica con huincha.

#### C.4 `Segmentation/` — multi-objeto, manual primero

Orden del pipeline: recorte ROI (caja orientada dibujada por el usuario) → remoción del
plano de soporte por RANSAC → componentes conexas sobre el grafo de adyacencia de
triángulos con corte por ángulo diedro y distancia → filtro por tamaño mínimo →
`OBBFitter` (PCA sobre los vértices, con el eje vertical opcionalmente forzado al de
gravedad) por componente.

**Decisión: la segmentación automática propone, el humano dispone.** El flujo primario es
que el operador delimita cada espécimen con una caja orientada y la automática solo
sugiere. Una segmentación errónea en un registro legal (dos huesos fusionados en un
"espécimen", o uno partido en dos) es peor que el trabajo manual, y los especímenes suelen
estar en contacto físico, que es exactamente donde las componentes conexas fallan.

`SpatialRelationBuilder` deriva la matriz de relaciones (distancia, azimut, cota relativa,
contacto) desde las `OrientedBox` en marco de sitio. Esa matriz es el entregable de
"asociación espacial" para el informe de rescate.

#### C.5 `Geo/` — georreferenciación honesta

- **`LocationProvider`** es un protocolo, no un envoltorio de `CLLocationManager`.
  Implementaciones: `CoreLocationProvider`, `ManualCoordinateProvider` (el topógrafo entrega
  un punto de control levantado con GNSS diferencial), `ExternalReceiverProvider`
  (receptor NMEA/MFi). Esta indirección permite que la app suba de "±5 m" a "±2 cm" sin
  tocar ningún otro módulo.
- **Burst de fijaciones, no una lectura.** Durante el escaneo se registra la serie completa
  de `CLLocation` con su `horizontalAccuracy` y su `timestamp`. La coordenada del sitio es
  la mediana ponderada por precisión, y **se persiste la serie entera**, no solo el
  resultado. Un perito puede cuestionar un punto; no puede cuestionar una serie con su
  dispersión declarada.
- **`FixQualityGate`**: si la mejor precisión horizontal supera el umbral (p. ej. 10 m), el
  escaneo se marca `georeferenceQuality: .degraded` y esa marca viaja hasta el PDF
  exportado.
- **`UTMConverter`**: series de Krüger de orden 8 (precisión sub-milimétrica), no
  aproximaciones truncadas. Selección automática de huso: Chile continental abarca **18S y
  19S**; Isla de Pascua cae en 12S; el territorio antártico requiere UPS. Se persiste
  siempre el **código EPSG explícito** (32718 / 32719 / 32712) junto al datum. Nota de
  dominio: los planos históricos chilenos pueden estar en PSAD56/SAD69; la transformación de
  datum queda fuera de alcance, pero el datum usado se declara explícitamente en cada export
  para que nadie superponga capas incompatibles por accidente.
- **`TrackYawSolver`**: resuelve el yaw del marco AR respecto al norte verdadero ajustando
  la trayectoria de la cámara (en el plano horizontal) contra la traza GPS mediante
  alineación de Horn 2D. Con un recorrido de 15-20 m y GPS de 3-5 m, el yaw resultante es
  sustancialmente mejor que la brújula y tiene una incertidumbre calculable. El heading
  magnético se guarda como control cruzado; una discrepancia grande se reporta.
- **`MeridianConvergence`**: al convertir el marco local ENU a coordenadas de cuadrícula UTM
  hay que rotar por el ángulo de convergencia meridiana γ. En Chile γ puede alcanzar 1-2°;
  sobre un área de rescate de 20 m eso son ~0.7 m de error en los extremos si se ignora. Se
  aplica la rotación y se documenta el factor de escala (k₀ = 0.9996, ~8 mm en 20 m,
  despreciable pero declarado).

**Convención de marcos, fijada de una vez:** geometría en **metros**, `Float` para
posiciones, `Double` para acumuladores de volumen. `SiteFrame` usa la misma convención que
ARKit `.gravityAndHeading`: **+X = Este, +Y = Arriba, −Z = Norte** (mano derecha). La
conversión a UTM es `E = origin.E + x`, `N = origin.N + (−z)`, `h = origin.h + y`, tras
aplicar la convergencia meridiana.

#### C.6 `Custody/` — sellado y verificación

- **Hash**: SHA-256 (CryptoKit) en streaming sobre cada archivo del escaneo → `manifest`
  con `(rutaRelativa, bytes, sha256)` → el manifiesto se codifica canónicamente y se
  hashea → `rootHash`.
- **Firma**: clave P-256 en Secure Enclave (`SecureEnclave.P256.Signing.PrivateKey`), no
  exportable, protegida con `SecAccessControl` `.biometryCurrentSet + .privateKeyUsage`.
  **Sellar requiere Face ID del operador**, lo que convierte el no-repudio de "este
  dispositivo" en "este dispositivo con la biometría del operador presente". Es lo máximo
  alcanzable sin backend ni PKI, y hay que decirlo así en la documentación.
- **Cadena**: `seals/chain.jsonl` append-only; cada sello lleva `index`, `prevSealHash`,
  `rootHash`, `manifest`, `geo`, `author`, `deviceKeyID`, `publicKey`, `signature`.
  Encadenar hace detectable el back-dating dentro de un expediente: no se puede insertar un
  sello entre dos existentes sin romper la cadena.
- **Tiempo**: se registran tres fuentes — reloj de pared del dispositivo, delta monótono
  (`ContinuousClock`/boot time) desde el sello anterior, y el `timestamp` de la fijación
  GNSS asociada. El esquema del sello incluye un campo opcional `rfc3161Token` **vacío por
  diseño**, para que el día que se acepte una llamada de red a una TSA se pueda agregar sin
  romper el formato ni invalidar sellos existentes.
- **Rotación de clave**: si el usuario cambia de dispositivo o restaura, la clave del Secure
  Enclave se pierde. La cadena admite un evento `keyRotation` firmado por la clave nueva que
  declara la anterior; los sellos viejos siguen verificándose con la clave pública
  almacenada en cada sello.
- **WORM**: tras sellar, el directorio del escaneo se marca de solo lectura y se escribe
  `.sealed`. La app nunca reescribe un escaneo sellado.
- **`ChainVerifier`** es una función pura que devuelve `CustodyVerdict` con el detalle por
  archivo. Debe ser invocable desde la UI ("verificar expediente") y debe existir además
  como documento `VERIFY.txt` en cada export explicando cómo reproducir los hashes con
  `shasum` desde una terminal, sin la app. Un esquema de verificación que solo funciona
  dentro de la app que produjo la evidencia no vale nada ante un perito.

#### C.7 `Registration/` — alineación y diff

**Cascada de tres niveles, de más a menos confiable:**

1. **Objetivos de control físicos.** `ARReferenceImage` sobre marcas codificadas impresas y
   fijadas permanentemente en el sitio (3 o más, no colineales). `ControlTargetDetector` las
   reconoce automáticamente en ambos escaneos y produce la transformación por Umeyama de
   forma cerrada. Esto convierte el monitoreo multitemporal de un problema mal condicionado
   en uno resuelto, y de paso da una verificación independiente de escala. **Es la
   recomendación operativa principal para la capacidad de monitoreo.**
2. **Landmarks marcados por el usuario**: el operador toca tres puntos correspondientes en
   ambas mallas (esquinas de roca, hitos). Horn/Umeyama cerrado.
3. **Georreferencia + gravedad**: da la inicialización burda (±3-10 m en traslación, ±yaw
   del `TrackYawSolver`).

Cualquiera de los tres inicializa el **ICP punto-a-plano** de refinamiento:

- Submuestreo por vóxel multiresolución (20 cm → 10 cm → 5 cm), 20-50k puntos en el nivel
  fino.
- Correspondencias por hash espacial de vóxeles (no KD-tree: la construcción es más barata
  y el acceso es O(1) amortizado).
- ICP recortado: se descarta el 20-30% peor de las correspondencias por residuo, más test
  de compatibilidad de normales (ángulo < 45°).
- Gauss-Newton sobre 6 DOF, sistema 6×6 resuelto con `simd`/Accelerate.
- **Se alinea sobre la región estable, excluyendo explícitamente la zona donde se espera el
  cambio.** Si se alinea usando la superficie que cambió, el ICP absorbe el cambio en la
  transformación y el diff sale cero. Este es el error clásico y hay que hacerlo imposible
  por diseño: el usuario marca la "zona de interés de cambio" y el alineador usa su
  complemento.
- **`DegeneracyCheck`**: número de condición del Hessiano 6×6 del ICP. Una pared rocosa
  plana es geométricamente degenerada (el deslizamiento a lo largo del plano no está
  restringido). Si la condición supera el umbral, **el módulo se niega a reportar un diff**
  y exige objetivos de control o landmarks. Reportar un diff mal alineado como "remoción
  ilegal de material" es un falso positivo con consecuencias legales.

**`DiffEngine`**: tras alinear, distancia firmada punto-a-superficie de cada vértice de B
contra los triángulos de A (acelerada por el mismo hash espacial). Umbral de cambio
significativo = `max(3 × RMSE_registro, ruido_LiDAR ≈ 0.02 m)`. Salida: `DiffResult` con
campo escalar por vértice (para el mapa de calor), clusters de cambio conexos con su volumen
individual, y volumen ganado/perdido total obtenido rasterizando ambos escaneos a una grilla
común con el `SignedHeightFieldIntegrator` (para afloramientos verticales, la grilla se
define sobre el plano de pared, no sobre el horizontal). Cada cifra viaja con su banda de
incertidumbre.

### 2.D Formatos de exportación por caso de uso

| Caso de uso | Formato principal | Complementos | Razón |
|---|---|---|---|
| **Informe CMN** | **PDF/A** generado en dispositivo | `record.json`, `GeoJSON` + `KML` del polígono del sitio, PNG de vistas | Es lo que una institución recibe y archiva. El PDF lleva planta, perfil, tabla de mediciones con incertidumbres, coordenadas UTM con EPSG, `rootHash` en texto y como QR |
| **Peritaje legal** | **Bundle sellado** (`.zip` del directorio del hallazgo) | `mesh.ply` binario LE, `chain.jsonl`, `manifest.json`, `VERIFY.txt`, PDF | PLY binario: abierto, simple, byte-determinista, y CloudCompare/MeshLab lo abren, que es lo que un perito realmente usa. E57 (ASTM E2807) es el estándar de levantamiento pero no hay escritor Swift confiable: se documenta la conversión PLY→E57 en escritorio |
| **Réplica museográfica / impresión 3D** | **STL binario** | `USDZ` (Quick Look/AR para museografía), `OBJ+MTL` si hay textura, cubo de escala de 10 mm incluido en el archivo | STL es el formato universal de slicers. STL no tiene unidades: se fija la convención **1 unidad = 1 mm** y se declara en el sidecar y en el nombre del archivo. Requiere malla estanca, orientación de caras consistente y decimación a un conteo imprimible |
| **Inventario / catastro del museo** | **CSV + JSON** (una fila por espécimen) | `LAS 1.4` con VLR OGC WKT del CRS, `GeoJSON` de puntos, thumbnails | El CSV entra a la planilla del museo; el LAS georreferenciado entra a QGIS/ArcGIS sin conversión. LAS 1.4 es escribible en ~300 líneas y es el idioma de la topografía |
| **Perfil estratigráfico** | **PDF** con orto-imagen rectificada + escala gráfica | `GeoTIFF` de la orto-imagen (o PNG + world file), CSV de potencias | El paleontólogo necesita la imagen métrica, no la malla |

**Sidecar `record.json` — obligatorio en todo export**, con este contenido mínimo:

```
schemaVersion, appVersion, buildID
device: modelo, iOS, sensor LiDAR, versión de ARKit
capture: duración, nº de anchors, cobertura %, rango de distancia al objetivo,
         eventos de trackingState (incluidas relocalizaciones), estado térmico,
         estadísticas del confidenceMap de profundidad
geo: serie completa de fijaciones, fix elegido, horizontalAccuracy, UTM + EPSG + datum,
     convergencia meridiana aplicada, método y sigma del yaw, calidad (.good/.degraded)
algorithms: por cada etapa → nombre, algorithmVersion, TODOS los parámetros, semilla RNG,
            iteraciones efectivas, nº de inliers, RMS de residuos
measurements: valor, unidad, método, isInferred, incertidumbre (±), supuestos
custody: rootHash, índice del sello, deviceKeyID, clave pública, firma, las tres marcas de tiempo
authorship: operador, rol, institución, nº de permiso CMN si aplica
disclaimer: texto fijo de que la georreferencia GPS no constituye levantamiento geodésico
```

La regla que hace defendible el sistema: **versión de algoritmo + parámetros + semilla en
cada export**, de modo que cualquier resultado se pueda recomputar exactamente desde el
bundle.

### 2.E Contratos Swift (fijados antes de escribir implementación)

```swift
// ═══════════════ Domain (cero imports de framework) ═══════════════

struct Mesh: Sendable, Equatable {
    var vertices: [SIMD3<Float>]
    var indices:  [UInt32]           // triples
    var normals:  [SIMD3<Float>]?    // por vértice, opcional
    var colors:   [SIMD4<UInt8>]?    // por vértice, opcional (mapas de calor)
    var triangleCount: Int { indices.count / 3 }
    var isEmpty: Bool { vertices.isEmpty || indices.isEmpty }
}

struct Plane: Sendable, Equatable, Codable {
    var point: SIMD3<Float>
    var normal: SIMD3<Float>          // invariante: unitaria
    var inlierRMS: Float?             // calidad del ajuste
    var inlierCount: Int?
}

struct OrientedBox: Sendable, Codable {
    var center: SIMD3<Float>
    var axes: simd_float3x3           // columnas ortonormales, orden por extensión desc
    var halfExtents: SIMD3<Float>
    var dimensions: SIMD3<Float> { halfExtents * 2 }   // largo, ancho, alto en metros
}

/// Marco del sitio: ENU con Y arriba (+X Este, +Y Arriba, −Z Norte). Convención ARKit.
struct SiteFrame: Sendable, Codable {
    var siteID: UUID
    var origin: UTMCoordinate          // origen geodésico
    var yawFromTrueNorth: Float         // rad, ya aplicado a arWorldToSite
    var yawSigma: Float
    var meridianConvergence: Float
}

struct UTMCoordinate: Sendable, Codable {
    var easting: Double
    var northing: Double
    var ellipsoidalHeight: Double
    var zone: Int
    var isNorthernHemisphere: Bool
    var epsg: Int                       // 32718 | 32719 | 32712 ...
    var datum: String                   // "WGS84"
}

struct GeoFix: Sendable, Codable {
    var latitude, longitude, altitude: Double
    var horizontalAccuracy, verticalAccuracy: Double
    var timestamp: Date
    var source: GeoSource               // .coreLocation | .manual | .externalReceiver
}

enum ScanPurpose: String, Sendable, Codable {
    case baseline, postIntervention, monitoring, damageAssessment
    case rescueDocumentation, specimenInventory, stratigraphicProfile
}

struct VolumeResult: Sendable, Codable {
    var positive: Double                // m³ sobre la superficie de referencia
    var negative: Double                // m³ bajo la superficie de referencia (cavidad/pérdida)
    var net: Double { positive - negative }
    var coveredArea: Double             // m²
    var filledCellRatio: Double         // fracción de celdas rellenadas por interpolación
    var uncertainty: Double             // ± m³ (1σ)
    var method: VolumeMethod            // .heightField | .closedMesh | .cavityRimFit | .cavityDiff | .mirrorSymmetry
    var isInferred: Bool                // true si la superficie de referencia es una inferencia
    var algorithmVersion: String
}

// ═══════════════ Geometry ═══════════════

enum OrientationConstraint: Sendable, Codable {
    case none
    case horizontal(maxTiltDegrees: Float)                     // suelo
    case vertical(maxTiltDegrees: Float)                       // pared de corte
    case nearNormal(SIMD3<Float>, toleranceDegrees: Float)
}

struct PlaneFitOptions: Sendable, Codable {
    var maxIterations: Int = 500
    var inlierDistance: Float = 0.02        // m
    var minInliers: Int = 50
    var constraint: OrientationConstraint = .none
    var scoring: Scoring = .msac            // .inlierCount | .msac
    var confidence: Float = 0.99            // corte adaptativo de iteraciones
    var rngSeed: UInt64                     // OBLIGATORIO: determinismo reproducible
}

protocol PlaneFitting: Sendable {
    static var algorithmVersion: String { get }
    func fit(points: [SIMD3<Float>],
             normals: [SIMD3<Float>]?,
             options: PlaneFitOptions) throws(GeometryError) -> Plane
}
// Implementaciones: LeastSquaresPlaneFitter, RANSACPlaneFitter

protocol BoxFitting: Sendable {
    func fit(points: [SIMD3<Float>], gravityAlignedUpAxis: Bool) -> OrientedBox
}

// ═══════════════ Volume ═══════════════

enum EmptyCellStrategy: Sendable, Codable { case ignore, fillInteriorHoles }

protocol VolumeIntegrating: Sendable {
    static var algorithmVersion: String { get }
    func integrate(mesh: Mesh,
                   reference: ReferenceSurface,
                   cellSize: Float,
                   emptyCells: EmptyCellStrategy) throws(VolumeError) -> VolumeResult
}

enum ReferenceSurface: Sendable {
    case plane(Plane)
    case quadric(QuadricSurface)            // ajustada al anillo intacto
    case priorScan(Mesh, alignment: simd_float4x4)
    case mirror(plane: Plane)
    case closedSolid                        // sin referencia: divergencia sobre malla cerrada
}

protocol MeshClosing: Sendable {
    func close(mesh: Mesh, against plane: Plane?) -> (mesh: Mesh, report: WatertightnessReport)
}

// ═══════════════ Segmentation ═══════════════

struct SegmentedComponent: Sendable {
    var vertexIndices: [UInt32]
    var box: OrientedBox
    var triangleCount: Int
    var classificationHint: String?         // de ARMeshClassification
}

protocol MeshSegmenting: Sendable {
    func segment(mesh: Mesh,
                 roi: OrientedBox?,
                 removingPlane: Plane?,
                 options: SegmentationOptions) -> [SegmentedComponent]
}

// ═══════════════ Geo ═══════════════

protocol LocationProviding: AnyObject, Sendable {
    var fixes: AsyncStream<GeoFix> { get }
    func start() async throws(GeoError)
    func stop()
}

protocol GeodeticConverting: Sendable {
    func toUTM(latitude: Double, longitude: Double, height: Double) throws(GeoError) -> UTMCoordinate
    func toGeodetic(_ utm: UTMCoordinate) throws(GeoError) -> (lat: Double, lon: Double, h: Double)
    func meridianConvergence(latitude: Double, longitude: Double, zone: Int) -> Double
}

protocol SiteFrameResolving: Sendable {
    /// Resuelve el marco de sitio alineando la trayectoria AR contra la traza GPS.
    func resolve(cameraTrack: [(time: Date, transform: simd_float4x4)],
                 fixes: [GeoFix],
                 magneticHeading: Double?) throws(GeoError) -> (frame: SiteFrame, arWorldToSite: simd_float4x4)
}

// ═══════════════ Registration ═══════════════

struct AlignmentResult: Sendable, Codable {
    var transform: simd_float4x4         // B → A
    var rmse: Float                      // m
    var inlierRatio: Float
    var iterations: Int
    var conditionNumber: Float           // degeneración del Hessiano 6×6
    var isDegenerate: Bool
    var initializationMethod: InitMethod  // .controlTargets | .landmarks | .geodetic
}

protocol MeshRegistering: Sendable {
    static var algorithmVersion: String { get }
    func align(source: Mesh, target: Mesh,
               initial: simd_float4x4,
               stableRegionMask: RegionMask?,     // complemento de la zona de cambio esperado
               options: ICPOptions) throws(RegistrationError) -> AlignmentResult
}

struct DiffResult: Sendable, Codable {
    var alignment: AlignmentResult
    var signedDistances: [Float]          // por vértice del escaneo posterior
    var changeThreshold: Float            // max(3·rmse, ruidoLiDAR)
    var lostVolume, gainedVolume: Double  // m³
    var volumeUncertainty: Double
    var clusters: [ChangeCluster]
}

protocol MeshDifferencing: Sendable {
    func diff(baseline: Mesh, current: Mesh,
              alignment: AlignmentResult,
              cellSize: Float) throws(RegistrationError) -> DiffResult
}

// ═══════════════ Custody ═══════════════

struct SealRecord: Sendable, Codable {
    var index: Int
    var prevSealHash: String?             // hex SHA-256; nil solo en el índice 0
    var rootHash: String
    var manifest: [FileDigest]
    var geo: GeoFix?
    var author: AuthorIdentity
    var deviceKeyID: String
    var publicKeyDER: Data
    var signatureDER: Data
    var wallClock: Date
    var monotonicDeltaSincePrevious: TimeInterval?
    var gnssTime: Date?
    var rfc3161Token: Data?               // reservado: siempre nil sin backend
}

protocol Sealing: Sendable {
    func seal(bundleAt url: URL, author: AuthorIdentity, geo: GeoFix?) async throws(CustodyError) -> SealRecord
}

protocol ChainVerifying: Sendable {
    func verify(bundleAt url: URL) async throws(CustodyError) -> CustodyVerdict
}

// ═══════════════ Persistence ═══════════════

protocol FindingStoring: Sendable {
    func createFinding(_ finding: Finding) async throws(StoreError) -> URL
    func appendScan(_ scan: ScanSession, mesh: Mesh, to findingID: UUID) async throws(StoreError) -> URL
    func loadMesh(scanID: UUID, findingID: UUID) async throws(StoreError) -> Mesh
    func listFindings() async throws(StoreError) -> [FindingSummary]
    func rebuildIndex() async throws(StoreError)        // el índice es derivado y descartable
}

// ═══════════════ Export ═══════════════

enum ExportFormat: String, Sendable, Codable {
    case plyBinary, stlBinary, obj, usdz, las14, geoJSON, kml, csv, pdfReport
}

protocol MeshExporting: Sendable {
    var format: ExportFormat { get }
    /// Debe ser byte-determinista: misma entrada ⇒ mismos bytes.
    func write(mesh: Mesh, metadata: ExportMetadata, to url: URL) throws(ExportError)
}

// ═══════════════ Capture (único con dependencia ARKit) ═══════════════

protocol MeshCapturing: AnyObject {
    var coverage: AsyncStream<CoverageSnapshot> { get }
    var trackingEvents: AsyncStream<TrackingEvent> { get }
    func start(purpose: ScanPurpose) throws(CaptureError)
    func finish() async throws(CaptureError) -> CaptureBundle   // mesh + track + fixes + frames
}

// ═══════════════ Rendering (único con dependencia SceneKit) ═══════════════

protocol ScanRendering: AnyObject {
    func present(mesh: Mesh, colorField: [Float]?, palette: ColorPalette?)
    func overlay(plane: Plane, extent: Float)
    func overlay(boxes: [OrientedBox], labels: [String])
    func pick(at screenPoint: CGPoint) -> SIMD3<Float>?
}
```

**Reglas de compatibilidad entre sesiones paralelas de LLM** (deben ir al `CLAUDE.md` del
proyecto nuevo):

1. Nada en `Domain/`, `Geometry/`, `Volume/`, `Segmentation/`, `Registration/`, `Custody/`,
   `Export/` importa ARKit, SceneKit, RealityKit ni UIKit. Se testea con mallas sintéticas.
2. Toda geometría en metros; `Float` en posiciones, `Double` en acumuladores de volumen y
   coordenadas geodésicas.
3. Marco de sitio: +X Este, +Y Arriba, −Z Norte.
4. Todo algoritmo estocástico recibe `rngSeed` explícita y expone `algorithmVersion`.
5. `throws` tipados; nada de `try?` silencioso ni valores centinela.
6. Inyección por protocolo con parámetro por defecto; sin singletons.
7. Escrituras a disco atómicas (temporal + `replaceItemAt`), y nunca sobre un directorio con
   `.sealed`.
8. Los serializadores de export deben pasar tests de golden-file por hash.

### 2.F Riesgos técnicos del dominio

**1. Precisión del LiDAR frente a la exigencia centimétrica de la potencia del estrato.**
La malla de `ARMeshAnchor` tiene triángulos de ~5-10 cm y está suavizada; el ruido de
profundidad es de 1-2 cm a 1-2 m y crece rápido más allá. Declarar una potencia de 5 cm con
esa base es declarar ruido. Mitigaciones incorporadas al diseño: nube densa propia desde
`sceneDepth` filtrada por `confidenceMap`, captura a 0.5-1.5 m, promediado multi-frame, y
sobre todo **la potencia se mide sobre la orto-imagen rectificada, no sobre la geometría**.
Bajo un umbral configurable (sugerido 3 cm) la app no entrega una cifra sin exigir
documentación fotográfica con huincha. Toda potencia se reporta como `valor ± σ`, nunca
como número pelado.

**2. Deriva y sesgo del GPS del iPhone en terreno.** Sin RTK, la precisión horizontal real
es de 3-5 m a cielo abierto y 10-30 m junto a un corte de talud, maquinaria o quebrada. No
sirve para deslinde catastral. Consecuencias de diseño: (a) el disclaimer de "no constituye
levantamiento geodésico" es parte del schema de export, no un texto de la UI; (b) las
mediciones legalmente relevantes son las **relativas** (dimensiones, potencia, volumen), con
precisión de ARKit, y el GPS es solo el ancla de ubicación; (c) `LocationProviding` como
protocolo permite sustituir CoreLocation por un punto de control levantado por topógrafo o un
receptor externo sin tocar el resto. La altura GNSS del iPhone es la peor componente
(±10-20 m, además elipsoidal vs. ortométrica sin modelo de geoide): **no usar la cota GPS
para nada métrico**, solo la cota relativa al marco de sitio.

**3. Deriva de ARKit en escaneos largos y relocalizaciones.** El world tracking acumula
error de decenas de centímetros en recorridos de 10-20 m, y una relocalización tras
interrupción **rompe la continuidad métrica** del escaneo. Mitigación: registrar todos los
eventos de `trackingState` en la metadata y marcar el escaneo como sospechoso ante
`.limited(.relocalizing)`; dividir áreas grandes en escaneos acotados unidos por objetivos
de control en vez de un único recorrido largo; monitorear tiempo de sesión y advertir.

**4. Viabilidad de ICP on-device.** Es viable con holgura: 20-50k puntos tras submuestreo por
vóxel, hash espacial, 30-50 iteraciones Gauss-Newton con `simd` → del orden de 1-3 s en A15
o superior, en un actor de fondo. El riesgo no es el costo, es la **convergencia**: un
afloramiento rocoso plano es geométricamente degenerado (deslizamiento libre en el plano), y
superficies auto-similares producen mínimos locales. Por eso el `DegeneracyCheck` sobre el
número de condición del Hessiano es obligatorio y la app **se niega** a reportar un diff
degenerado. Segundo riesgo, más insidioso: alinear sobre la zona que cambió anula el cambio.
Se resuelve por diseño con la máscara de región estable. Recomendación operativa que resuelve
ambos: **dejar objetivos de control físicos permanentes en los sitios bajo monitoreo del
art. 31**.

**5. Objetos grandes a más de 5 m (ballenas, mastodontes).** El alcance útil del LiDAR es
~5 m con degradación notoria sobre 3 m. Un espécimen de 10 m obliga a múltiples pasadas
cercanas → sesión larga → deriva → malla de millones de triángulos → presión de memoria y
térmica. Mitigaciones: captura por teselas con objetivos de control; simplificación por
vóxel de 1-2 cm en el merger; fusión con volcado incremental a disco; monitoreo de
`ProcessInfo.thermalState` con degradación explícita (bajar resolución, avisar) en vez de
que iOS mate el proceso; y priorizar el flujo "dimensiones primero" (caja orientada +
volumen estimado), que es lo que la planificación de extracción y embalaje realmente
necesita y tolera ±5%. Además, el integrador de campo de alturas **subestima
sistemáticamente** cualquier pieza con voladizos: la política debe enrutar estos casos al
`ClosedMeshIntegrator` y exponer el diagnóstico de estanqueidad.

**6. La superficie de referencia del daño es una inferencia, no una medición.** Cuantificar
"material perdido" sin escaneo previo requiere reconstruir una superficie que ya no existe.
El diseño lo hace explícito (`isInferred`, `method`, supuestos en el sidecar), pero el
riesgo de comunicación persiste: un informe que presente un volumen inferido como medido es
atacable en juicio. La UI debe rotular diferente ambos casos, y el argumento comercial
fuerte es que el registro preventivo (capacidad 1) es lo que convierte la inferencia en
medición.

**7. Límites reales de la cadena de custodia sin backend.** Hay que decirlo sin adornos en
la documentación del producto: el sello prueba **integridad del archivo desde el sellado** y
**origen en este dispositivo con biometría del operador presente**. No prueba (a) tiempo
absoluto — el reloj del dispositivo es alterable, y solo mitigamos con encadenamiento, delta
monótono y hora GNSS; (b) que la escena no haya sido manipulada físicamente antes de
escanear; (c) identidad respaldada por una autoridad certificadora. El campo `rfc3161Token`
reservado deja la puerta abierta al único upgrade que da tiempo absoluto. Riesgo operativo
adicional: pérdida del dispositivo elimina la clave privada — los sellos existentes siguen
verificables, pero el evento `keyRotation` debe estar implementado desde el inicio o el
expediente se rompe al cambiar de teléfono.

**8. Radiación solar directa: el modo de falla más subestimado en terreno chileno.** El
LiDAR dToF del iPhone se satura con luz solar intensa; en el norte de Chile a mediodía la
reconstrucción puede degradarse a punto de inutilidad. Consecuencias: medidor de calidad de
profundidad en vivo derivado del `confidenceMap`, bloqueo de finalización bajo un umbral de
confianza, y guía de operación (sombra, cielo cubierto, primeras y últimas horas). Esto debe
estar en la UI de captura desde el día 1, no como mejora posterior.

**9. Determinismo numérico.** RANSAC no sembrado, concurrencia con reducciones en orden
variable y acumulación en `Float` producen resultados distintos para la misma entrada. Para
un artefacto legal es descalificante. Reglas: semilla explícita, orden de reducción fijo,
acumuladores en `Double`, y una prueba de regresión que reprocese un bundle de referencia y
exija hash idéntico del `record.json` de mediciones.

**10. Autonomía, almacenamiento y jornada de terreno.** 30-100 MB por escaneo más frames de
cámara; una jornada de rescate genera varios GB. Se necesita un modo "capturar ahora,
procesar después" (el procesamiento pesado se difiere y se ejecuta enchufado), monitoreo de
espacio libre con bloqueo preventivo, y advertencia de batería antes de iniciar un escaneo
largo.

**11. Riesgo de sobre-promesa regulatoria.** La app documenta; no autoriza ni sustituye la
intervención del CMN. Los exports deben registrar el número de permiso cuando exista y
llevar un texto fijo que delimite el alcance. El `Finding` debe modelar `cmnNotification`
(fecha, canal, folio) como parte del expediente, porque el valor real de la capacidad 1 es
demostrar que se registró **antes** de intervenir y que se notificó.

### 2.G Estrategia de validación mínima antes de considerar la app apta para terreno

- Mallas sintéticas con volumen analítico conocido: cono, pirámide truncada, casquete
  esférico, **cavidad hemisférica** (para el volumen negativo), sólido con voladizo (para
  separar campo de alturas de divergencia).
- Pared sintética con estratos de espesor conocido y buzamiento conocido, incluyendo
  contactos inclinados que exponen la diferencia entre espesor real y aparente.
- Pares de diff sintéticos con desplazamiento y pérdida de volumen conocidos, más un caso
  degenerado (pared plana) que debe ser **rechazado** por el `DegeneracyCheck`.
- Vectores de control del `UTMConverter` contra puntos publicados en husos 18S y 19S.
- Tests golden-file por hash de cada exportador y del encoder canónico.
- Validación física: caja calibrada, regla graduada y un objeto de volumen conocido por
  desplazamiento de agua, ejecutados con la app y documentados como margen real declarado
  del producto.

(Esta lista es la base de fixtures; la Fase 16 de §3 la convierte en protocolo de terreno
con repeticiones y bandas de error.)

---

## 3. Fases de ejecución

### Nota previa sobre el orden (leer antes de ejecutar nada)

**El orden de las fases es por dependencia técnica, no por prioridad de negocio.** Las 9
capacidades funcionales tienen igual prioridad de producto: ninguna es un "extra de fase 2"
ni es descartable. Lo que impone el orden es que ciertos módulos no pueden escribirse sin
que otros existan primero (no se puede integrar volumen sin una malla fusionada; no se puede
sellar sin un bundle en disco; no se puede diffear sin registro). Que la capacidad 7
(monitoreo) aparezca en la Fase 11 no significa que valga menos que la capacidad 1: significa
que necesita once fases de cimiento debajo.

Tres reglas gobiernan todo el plan y no se negocian por fase:

1. **Ninguna fase algorítmica se declara terminada contra datos reales.** Cada algoritmo no
   trivial cierra contra verdad sintética conocida (geometría construida por fórmula) *antes*
   de tocar hardware. Esto separa el riesgo "el algoritmo está mal" del riesgo "la captura AR
   es ruidosa" — mezclarlos hace imposible saber cuál de los dos falló. Es la misma decisión
   que ya se tomó en StockIA al validar el integrador contra un cono y una pirámide truncada
   antes de conectar ARKit (`PLAN.md`, Fase 2).
2. **Ninguna cifra de precisión se promete: se mide** (Fase 16). Hasta que exista una
   medición propia, la UI no muestra número de precisión alguno.
3. **Módulo ≠ fase.** Una fase puede tocar archivos de varios módulos, y un módulo puede
   completarse en dos fases distintas (ej.: `Capture/ControlTargetDetector` es del módulo
   `Capture/` pero se implementa en la Fase 11, donde su valor se realiza). El árbol de
   carpetas de §2.C es la arquitectura; las fases son el orden de ejecución.

Convención de cada fase: **Qué hacer / Criterio de aceptación / Depende de / Capacidades /
Riesgos que mitiga / Archivos principales**.

### Mapa de paralelismo

**Cadenas estrictamente secuenciales (no se pueden solapar):**

- `F0 → F1 → (todo lo demás)`
- `F1 → F9 → F10 → F17`
- `F1 → F4 → F5`, `F1 → F4 → F7`, `F1 → F4 → F11`
- `F2 → F6`, `F2 → F7`, `F2 → F11`
- `F0 → F3 → F13 → F14`
- `F14 → F15 → F16 → F17`

**Olas de ejecución** (dentro de cada ola las fases son independientes entre sí y pueden
ejecutarlas sesiones distintas en paralelo sin pisarse):

| Ola | Fases en paralelo | Naturaleza |
|---|---|---|
| 0 | F0 | Bloquea todo |
| 1 | F1 | Fija contratos; bloquea todo lo demás |
| 2 | **F2, F3, F4, F8, F9** | F3 es la única que requiere dispositivo; el resto es matemática pura |
| 3 | **F5, F6, F7, F10, F13** | F13 requiere dispositivo |
| 4 | **F11, F12** | Las dos más pesadas; independientes entre sí |
| 5 | F14 | Integra todo; secuencial por definición |
| 6 | F15 | Requiere el flujo end-to-end vivo |
| 7 | F16 | Terreno |
| 8 | F17 | Cierre probatorio |

**Separación de riesgo tipo StockIA:** la Ola 2 contiene el equivalente exacto de la
separación "Fase 1 ARKit ∥ Fase 2 algoritmo sintético" de StockIA, pero ampliada a cuatro
hilos: `F3` (riesgo de hardware/captura) corre en paralelo a `F2/F4/F8/F9` (riesgo puramente
algorítmico y de formato). Si `F3` se atasca en el parseo de buffers de `ARMeshGeometry` —
históricamente la parte más ardua —, el proyecto sigue avanzando en los otros tres hilos.

---

### Fase 0 — Entorno, proyecto Xcode y guardas de build

**Qué hacer:** crear el proyecto desde cero con el checklist completo de §4 (bundle ID
definitivo, deployment target, capabilities, textos exactos de Info.plist, target de tests,
y las **guardas de build de determinismo**: sin `-Ofast`, sin fast-math,
`SWIFT_STRICT_CONCURRENCY = complete`). Correr un "Hello World" SwiftUI en el iPhone físico
y un test vacío en el target de tests.

**Criterio de aceptación:**
- La app abre en el iPhone conectado por cable y vuelve a abrir tras reiniciar el teléfono.
- `xcodebuild test` corre en verde con un test trivial, tanto en Debug como Release.
- Un test que lee las tres claves de Info.plist requeridas (`NSCameraUsageDescription`,
  `NSLocationWhenInUseUsageDescription`, `NSFaceIDUsageDescription`) y falla si alguna está
  vacía o ausente. Es barato y evita el rechazo silencioso de permisos en terreno.
- El bundle ID queda registrado en el README y **no se vuelve a cambiar** (la cuenta
  gratuita tiene cuota de 3 App IDs por ventana móvil de 7 días).

**Depende de:** nada. Bloquea todo.
**Capacidades:** habilita las 9, no implementa ninguna.
**Riesgos que mitiga:** determinismo numérico (banderas de compilador fijadas antes de
escribir la primera línea de matemática, no después); fricción de firma.
**Archivos principales:** proyecto Xcode, `Info.plist`, `PaleoRegistroTests/InfoPlistContractTests.swift`.

---

### Fase 1 — `Domain/`: tipos puros, errores tipados y guarda de arquitectura

**Qué hacer:** escribir todos los tipos de dominio (§2.E) con sus `Codable`, sus errores
tipados y sus invariantes validadas en el inicializador (normal unitaria, semiejes
positivos, huso UTM válido). Cero imports de framework. Añadir el **script de guarda de
arquitectura** que falla el build si aparece `import ARKit|SceneKit|RealityKit|CoreLocation|SwiftData`
en cualquier archivo bajo `Domain/`, `Geometry/`, `Mesh/`, `Volume/`, `Stratigraphy/`,
`Segmentation/`, `Registration/`.

**Criterio de aceptación:**
- El target de tests compila y corre **sin enlazar ARKit, SceneKit ni CoreLocation**
  (verificable: el test target no los lista en Frameworks).
- La guarda de arquitectura falla deliberadamente cuando se le agrega `import SceneKit` a
  un archivo de `Domain/` de prueba, y vuelve a pasar al quitarlo. **Probar que la guarda
  falla es parte del criterio** — una guarda que nunca se vio fallar no es una guarda.
- Round-trip `Codable` de un `Finding` completo con todos los campos poblados devuelve un
  valor igual al original.
- Los inicializadores rechazan entradas inválidas con el error tipado correcto (normal de
  norma 0, huso 20, semieje negativo, `GeoFix` con precisión negativa).

**Depende de:** F0.
**Capacidades:** todas (es la base de las 9).
**Riesgos que mitiga:** deriva de contratos entre sesiones de LLM distintas (el problema
que ya se resolvió en StockIA fijando `Mesh`/`Plane`/protocolos el día uno); contaminación
de framework que bloquearía la migración futura a RealityKit.
**Archivos principales:** `Domain/*.swift`, `Scripts/check_module_boundaries.sh`.

---

### Fase 2 — `Geometry/`: ajuste de planos con restricción, OBB y rectificación

**Qué hacer:** `PlaneFitting` (mínimos cuadrados + RANSAC/MSAC genérico con
`OrientationConstraint` evaluada **dentro** del bucle de consenso, RNG sembrado vía
`PlaneFitOptions.rngSeed`), `OBBFitting` por PCA, `Rectifier` (orto-imagen sobre plano).

**Criterio de aceptación — todo con verdad sintética, sin dispositivo:**
- **Test crítico de la restricción de orientación:** nube que contiene un piso horizontal
  con 800 puntos y un muro vertical con 300 puntos. Con `OrientationConstraint.vertical`,
  el ajuste debe devolver **el muro**, aunque el piso tenga más del doble de inliers. Este
  test demuestra que la restricción está dentro del bucle y no aplicada como filtro
  posterior; si estuviera fuera, el resultado sería el piso o `nil`. Tolerancia: ángulo
  contra la normal real < 0.5°, offset < 5 mm.
- Plano inclinado de normal conocida con 20% de outliers en un segundo plano: ángulo < 0.5°,
  offset < 5 mm.
- **Determinismo:** 50 corridas con la misma `rngSeed` producen resultados **idénticos bit a
  bit** (comparar la serialización canónica del `Plane`, no comparar floats con tolerancia).
  Con semillas distintas, los resultados difieren entre sí menos que la tolerancia anterior.
- Caso sin consenso (puntos sobre una esfera) y caso colineal devuelven el error tipado
  correspondiente, no un plano basura.
- **OBB:** caja de 0.30 × 0.20 × 0.10 m rotada por yaw 37° y pitch 12° → dimensiones
  recuperadas dentro de 1 mm, ejes dentro de 1° (aceptando permutación y signo de ejes, que
  la PCA no fija).
- Caso degenerado de OBB: nube casi plana (una cara sin espesor) → el semieje menor tiende a
  0 sin producir `NaN`.
- **Rectifier:** damero sintético de nodos de 5 cm sobre un plano inclinado conocido → tras
  rectificar, la distancia entre nodos adyacentes se recupera dentro de 1 mm y las líneas
  del damero quedan paralelas a los ejes de la imagen dentro de 0.3°.

**Depende de:** F1.
**Capacidades:** 2 (perfiles estratigráficos), 6 (multi-especimen), 9 (inventario
volumétrico), 7 (registro).
**Riesgos que mitiga:** determinismo numérico (semilla + prueba bit a bit); error de
estratigrafía por ajustar el plano equivocado en un corte donde el piso domina la nube.
**Archivos principales:** `Geometry/PlaneFitting.swift`, `Geometry/OBBFitting.swift`,
`Geometry/Rectifier.swift`, `PaleoRegistroTests/SyntheticGeometry.swift`.

---

### Fase 3 — `Capture/` mínimo + `Rendering/` mínimo: ARKit vivo y malla en mano

**Qué hacer:** `ARSessionManager` con la configuración decidida en §2.A
(`.meshWithClassification`, `[.sceneDepth, .smoothedSceneDepth]`, `.gravity`),
`MeshAnchorReader` (parseo de buffers `ARMeshGeometry` → `Domain.Mesh`), `DepthAccumulator`
(nube densa desde `sceneDepth` + `confidenceMap`), `CoverageTracker`, `PhotoCapture`, y la
implementación mínima de `ScanRendering` con overlay wireframe + HUD de diagnóstico
(anchors, vértices, estado de tracking, temperatura, disco libre).

**Criterio de aceptación:**
- Caminando por una sala, se ve el wireframe de la reconstrucción sobre el feed de cámara y
  el HUD actualiza contadores en vivo.
- `MeshAnchorReader` produce un `Domain.Mesh` que se escribe a PLY crudo y **abre
  correctamente en un visor de escritorio** (MeshLab, Blender o Preview) con la geometría
  reconocible. Este paso saca el resultado del teléfono y lo verifica con una herramienta
  independiente.
- **Prueba de ruido del sensor, medida no asumida:** apuntar a una pared plana real a 1.5 m
  durante 10 s; ajustar el plano con `PlaneFitting` (F2) y reportar la desviación estándar
  de los residuos. Se registra el número; no se compara contra ninguna expectativa. Es la
  primera medición propia del ruido del LiDAR de este dispositivo.
- `DepthAccumulator` produce, sobre esa misma pared, una nube con **al menos un orden de
  magnitud más puntos** que `ARMeshAnchor` en la misma superficie, y su σ de residuos se
  reporta junto a la del mesh (para saber si la nube densa realmente aporta o solo añade
  ruido).
- El descarte por `confidenceMap` es verificable: filtrar por confianza baja reduce el
  conteo de puntos y no aumenta σ.
- Ningún tipo de `Domain/` importa ARKit (la guarda de F1 sigue en verde).

**Depende de:** F0 y F1. **No depende de F2, F4, F5, F8 ni F9** — corre en paralelo a todas
ellas.
**Capacidades:** 1 (registro 3D del hallazgo).
**Riesgos que mitiga:** riesgo de hardware aislado del riesgo algorítmico; primera medición
del ruido real del sensor antes de comprometer tolerancias en otras fases.
**Archivos principales:** `Capture/ARSessionManager.swift`, `Capture/MeshAnchorReader.swift`,
`Capture/DepthAccumulator.swift`, `Capture/CoverageTracker.swift`,
`Rendering/ScanRendering.swift`, `Rendering/SceneKitRenderer.swift`.

---

### Fase 4 — `Mesh/`: fusión, ROI, operaciones y cierre de malla

**Qué hacer:** `MeshMergeCore` (fusión y deduplicación de vértices), `ROIFilter` (recorte
por caja orientada), `MeshOps` (normales, componentes conexas, decimación), `MeshCloser`
(tapado de malla para sólido cerrado).

**Criterio de aceptación — verdad sintética:**
- Fusión de dos cubos sintéticos con solapamiento conocido: conteo de vértices tras
  deduplicar coincide con el valor calculado a mano; ninguna cara queda con índices fuera de
  rango.
- `ROIFilter` con caja orientada rotada 30°: conjunto de puntos con pertenencia conocida por
  construcción → 100% de aciertos; los triángulos cortados por el borde se tratan según la
  política declarada (incluir/excluir/partir) y hay un test por política.
- Componentes conexas: dos esferas disjuntas → exactamente 2 componentes; dos esferas que se
  tocan en un vértice → el test documenta el comportamiento elegido (1 ó 2) y lo fija.
- Decimación al 25%: el volumen del sólido cerrado cambia menos de 1% y la malla sigue
  siendo manifold.
- **`MeshCloser`:** hemisferio abierto de radio conocido → la malla cerrada es *watertight*
  (cada arista compartida por exactamente 2 caras) y cumple V − E + F = 2; el volumen del
  sólido cerrado es 2/3·π·r³ dentro de 1%.
- Caso adversarial de `MeshCloser`: malla con dos agujeros separados → cierra ambos; malla
  con un agujero no planar → cierra sin auto-intersección o falla con error tipado (no
  produce un sólido inválido en silencio).

**Depende de:** F1.
**Capacidades:** 1, 5, 6, 8 (réplicas STL exigen malla cerrada), 9.
**Riesgos que mitiga:** volumen fantasma por geometría fuera del ROI; réplicas 3D no
imprimibles por malla no estanca.
**Archivos principales:** `Mesh/MeshMergeCore.swift`, `Mesh/ROIFilter.swift`,
`Mesh/MeshOps.swift`, `Mesh/MeshCloser.swift`.

---

### Fase 5 — `Volume/`: tres integradores y política de enrutado

**Qué hacer:** `SignedHeightFieldIntegrator` (positivo y negativo), `ClosedMeshIntegrator`
(divergencia sobre malla cerrada), `CavityIntegrator` (diff contra escaneo previo →
superficie de referencia ajustada al anillo intacto → completado por simetría, cada nivel
marcado `isInferred`), y el enrutador de política que elige integrador según `ScanPurpose` y
geometría.

**Criterio de aceptación — verdad sintética con fórmula analítica:**
- Cono y pirámide truncada (mismos fixtures reusables de StockIA): error < 2% del volumen
  analítico en al menos tres resoluciones de grilla, y el error decrece monótonamente al
  afinar la grilla.
- **Volumen negativo:** cono invertido bajo el plano de referencia → magnitud igual al caso
  positivo dentro de 1% y **signo negativo**. Test que falla si el integrador aplica
  `max(0, h)` (el defecto conocido del integrador actual de StockIA que esta generalización
  corrige — ver `StockIA/Volume/VolumeIntegrator.swift`).
- Escena mixta (montículo + zanja adyacente): el resultado reporta volumen positivo y
  negativo **por separado**, no su suma neta. Test que falla si solo devuelve el neto.
- **Test que justifica el enrutado:** sólido con voladizo (hongo/alero sobre pedestal) de
  volumen analítico conocido → `SignedHeightFieldIntegrator` yerra por más de 20% (se afirma
  el fallo, no se oculta) y `ClosedMeshIntegrator` acierta dentro de 2%. Este par de asserts
  documenta por qué existen dos integradores.
- `ClosedMeshIntegrator` sobre esfera y toro: error < 1%; sobre malla no estanca: **falla
  con error tipado**, nunca devuelve un número.
- **`CavityIntegrator`, tres niveles con trazabilidad distinta:**
  - Con escaneo previo sintético: cubo con mordisco hemisférico → cavidad recuperada dentro
    de 2% y `isInferred == false`.
  - Sin previo, con anillo intacto suficiente: superficie de referencia ajustada → error
    documentado y `isInferred == true`.
  - Sin previo y sin anillo suficiente, completado por simetría → `isInferred == true` y el
    resultado incluye el método de inferencia usado.
  - **Test que falla si `isInferred` no está poblado correctamente en cualquiera de los
    tres.** Es el guardián del riesgo legal: confundir volumen medido con volumen inferido
    en un informe al CMN.
- **Determinismo:** acumuladores en `Double`, orden de suma estable → dos corridas sobre la
  misma malla dan el mismo `Double` bit a bit (comparar patrón de bits, no con tolerancia).

**Depende de:** F1, F4. (Los tests inyectan un `Plane` conocido por construcción, así que
**no espera a F2** — se aísla el error de integración del error de ajuste de plano, igual
que se hizo en StockIA.)
**Capacidades:** 5 (cuantificación de daños), 9 (inventario volumétrico), 1.
**Riesgos que mitiga:** volumen inferido vs. medido confundidos (el riesgo legal más caro
del proyecto); voladizos subestimados; determinismo numérico.
**Archivos principales:** `Volume/SignedHeightFieldIntegrator.swift`,
`Volume/ClosedMeshIntegrator.swift`, `Volume/CavityIntegrator.swift`, `Volume/VolumePolicy.swift`.

---

### Fase 6 — `Stratigraphy/`: perfil de pared, orto-imagen y potencia real

**Qué hacer:** `WallProfileBuilder` (`PlaneFitting` con `OrientationConstraint.vertical` +
`Rectifier`), `StratumBoundaryPicker` (el operador marca límites sobre la orto-imagen 2D, no
sobre la malla 3D), `ThicknessCalculator` (potencia aparente → potencia real usando manteo y
dirección de manteo).

**Criterio de aceptación — verdad sintética:**
- Pared sintética con manteo (dip) 25° y dirección de manteo 130°, con estratos de
  **potencia real conocida de 12.0 cm**: marcando los límites sobre la orto-imagen
  rectificada, la potencia real se recupera dentro de 2 mm, y el dip/dipDirection
  recuperados quedan dentro de 1°.
- **Test que demuestra el error que se está evitando:** el mismo caso, calculando potencia
  aparente en vez de real, da 13.2 cm. El test afirma explícitamente ambos números para que
  quede escrito en el repo por qué la corrección existe.
- Corte oblicuo al rumbo: la potencia real se recupera igual (invariante al ángulo de
  corte), la aparente no.
- Estrato horizontal medido en pared vertical: aparente = real (caso trivial que atrapa
  errores de signo en la trigonometría).
- Propagación de incertidumbre: cada potencia devuelta trae una banda derivada del σ de
  residuos del ajuste de plano y de la resolución de la orto-imagen. Test: al duplicar el
  ruido inyectado, la banda crece.
- La marcación de límites es reproducible: los mismos píxeles marcados producen la misma
  potencia bit a bit.

**Depende de:** F2 (el `Rectifier` y el ajuste con restricción vertical son prerequisito
duro).
**Capacidades:** 2 (perfiles estratigráficos / potencia de estrato).
**Riesgos que mitiga:** precisión del LiDAR vs. exigencia centimétrica — aquí se decide
**reportar banda de incertidumbre por medición** en vez de un número desnudo; error
sistemático de confundir potencia aparente con real.
**Archivos principales:** `Stratigraphy/WallProfileBuilder.swift`,
`Stratigraphy/StratumBoundaryPicker.swift`, `Stratigraphy/ThicknessCalculator.swift`.

---

### Fase 7 — `Segmentation/`: multi-especimen con humano en el bucle

**Qué hacer:** recorte ROI manual por caja orientada → remoción del plano de soporte →
componentes conexas como **sugerencia automática** → ajuste manual del operador por
especimen → `OBBFitting` por componente → `SpatialRelationBuilder` (distancia, azimut,
contacto).

**Criterio de aceptación — verdad sintética:**
- Escena con 5 elipsoides de posición, dimensión y orientación conocidas apoyados sobre un
  plano: se recuperan exactamente 5 componentes; dimensiones de OBB dentro de 3 mm; ejes
  principales dentro de 2°; azimut relativo entre pares dentro de 1°; distancias centro a
  centro dentro de 3 mm.
- **Caso adversarial "automático propone, humano dispone":** dos especímenes en contacto
  físico → el segmentador automático devuelve **1** componente (esto se afirma como
  comportamiento esperado, no como bug) y el test verifica que la operación de división
  manual produce las 2 cajas correctas dentro de la misma tolerancia. La arquitectura
  declara que el humano decide; el test lo prueba.
- Caso inverso: un especimen fragmentado por un hueco de cobertura → automático devuelve 2
  componentes, y la operación de fusión manual las une correctamente.
- Remoción del plano de soporte: un especimen semienterrado conserva su volumen sobre el
  plano y no pierde geometría por sobre-recorte (comparación contra el volumen analítico del
  casquete).
- `SpatialRelationBuilder` marca "contacto" cuando la distancia mínima entre mallas < umbral
  declarado, y el umbral es un parámetro nombrado, no una constante mágica.

**Depende de:** F2 (OBB) y F4 (componentes conexas, ROI).
**Capacidades:** 6 (documentación de rescate), 9.
**Riesgos que mitiga:** segmentación automática errónea aceptada en silencio; pérdida de la
información de asociación espacial, que es justamente el dato irrecuperable en un rescate.
**Archivos principales:** `Segmentation/*.swift`.

---

### Fase 8 — `Geo/`: UTM Krüger, calidad de fijación y yaw por trayectoria

**Qué hacer:** protocolo `LocationProviding` con tres implementaciones (CoreLocation,
entrada manual, receptor externo), persistencia del **burst completo** de fijaciones (no
solo el resultado), `FixQualityGate`, `UTMConverter` (Krüger orden 8, EPSG explícito
32718/32719/32712), `TrackYawSolver` (Horn 2D trayectoria-AR vs. traza-GPS),
`MeridianConvergence`.

**Criterio de aceptación — verdad sintética y puntos de control publicados, sin salir a
terreno:**
- **UTM contra referencia externa:** al menos 3 puntos de control publicados por huso (18S,
  19S, 12S) con coordenadas geográficas y UTM conocidas → error < 1 mm. Los puntos de
  control se transcriben al repo con su fuente citada.
- Ida y vuelta lat/lon → UTM → lat/lon sobre una grilla de 10 000 puntos que cubra el rango
  de latitudes de Chile continental e insular → error < 0.1 mm. Incluir puntos cerca del
  borde de huso y en latitudes extremas.
- **Cruce contra una implementación independiente:** los mismos puntos convertidos con
  `pyproj` desde `tools/check_utm.py` coinciden dentro de 1 mm. Dos implementaciones que se
  equivocan igual es improbable; una sola que se equivoca sola es lo normal.
- Convergencia meridiana comparada contra la fórmula cerrada en 100 puntos → error < 0.001°.
- Selección automática de huso correcta en los bordes (69°W, 72°W) y **rechazo explícito**
  de coordenadas fuera de los husos soportados, con error tipado.
- **`TrackYawSolver`:** trayectoria sintética de 60 m rotada por un yaw conocido de 47.3°,
  con ruido gaussiano de 1.5 m por fijación **y un sesgo constante de 3 m** → yaw recuperado
  dentro de 1.5°, y el test afirma que el sesgo constante **no afecta el resultado** (Horn
  elimina la traslación). Este test es la justificación escrita de por qué no se usa la
  brújula ni la posición GPS absoluta.
- Caso degenerado: trayectoria casi rectilínea o demasiado corta → el solver **se niega** a
  devolver yaw (error tipado), no devuelve un valor de baja calidad.
- `FixQualityGate` descarta fijaciones con precisión horizontal peor que el umbral, y **el
  burst completo queda persistido igual**, incluidas las descartadas, con la razón del
  descarte.
- Test que verifica que ninguna magnitud métrico-legal (volumen, potencia, distancia entre
  especímenes) consume una coordenada GPS absoluta: se hace inyectando un `LocationProviding`
  que devuelve coordenadas absurdas y afirmando que todas las mediciones métricas quedan
  idénticas.

**Depende de:** F1 únicamente. Es la fase con mayor paralelizabilidad de todo el plan.
**Capacidades:** 3 (georreferenciación UTM), 1, 7.
**Riesgos que mitiga:** deriva/sesgo del GPS del iPhone (el último test lo blinda
estructuralmente); brújula del teléfono no confiable cerca de metal o en terreno con
magnetismo; pérdida de trazabilidad de la calidad de la fijación.
**Archivos principales:** `Geo/UTMConverter.swift`, `Geo/TrackYawSolver.swift`,
`Geo/FixQualityGate.swift`, `Geo/LocationProviding.swift`, `tools/check_utm.py`.

---

### Fase 9 — `Persistence/`: bundle en disco, JSON canónico e índice reconstruible

**Qué hacer:** layout de bundle (§2.B), escritura atómica (temporal + rename),
`CanonicalJSONEncoder` (claves ordenadas, floats con formato fijo, rechazo de `NaN`/`Inf`),
esquema SwiftData como **índice derivado** y `rebuildIndex()`.

> Nota de orden: `Persistence/` se ejecuta **antes** que `Custody/`, invirtiendo el orden en
> que aparecen en la lista de módulos de §2.C. Sellar exige que exista el bundle en disco y
> el encoder canónico; al revés no se puede.

**Criterio de aceptación:**
- **Determinismo del encoder, la prueba dura:** el mismo `Finding` serializado en **dos
  procesos distintos** y en **Debug y Release** produce bytes idénticos (comparar SHA-256,
  no strings). Incluir floats problemáticos (0.1 + 0.2, valores muy pequeños, negativos
  cerca de cero) y afirmar que `-0.0` y `0.0` se serializan igual.
- Diccionarios con claves insertadas en orden distinto producen el mismo JSON.
- `NaN` e `Inf` producen error tipado, nunca `null` silencioso.
- **Reconstrucción del índice:** escribir 20 hallazgos, borrar por completo el store de
  SwiftData, correr `rebuildIndex()` → el índice reconstruido es igual al original campo por
  campo. Este test es lo que convierte "SwiftData es solo índice" de intención en propiedad
  verificada.
- **Seguridad ante corte:** simular fallo a mitad de escritura (inyectar error en el writer)
  → el bundle queda en el estado anterior íntegro, sin archivos parciales visibles.
- Un bundle escrito en el dispositivo se copia por Finder/Archivos a un computador y su
  estructura se lee sin la app.
- Test que falla si algún flujo lee un dato legal desde SwiftData en vez del disco.

**Depende de:** F1.
**Capacidades:** 4 (cadena de custodia), y es soporte de las 9.
**Riesgos que mitiga:** determinismo de hashes; pérdida de la fuente de verdad legal por
corrupción del store; migración de esquema de SwiftData rompiendo evidencia.
**Archivos principales:** `Persistence/BundleWriter.swift`, `Persistence/CanonicalJSON.swift`,
`Persistence/IndexStore.swift`.

---

### Fase 10 — `Custody/`: hash, firma en Secure Enclave y cadena append-only

**Qué hacer:** SHA-256 en streaming por archivo, manifiesto canónico, firma P-256 en Secure
Enclave con Face ID, cadena `seals/chain.jsonl` con `prevSealHash`, WORM a nivel de app,
`ChainVerifying` y `VERIFY.txt`.

**Criterio de aceptación — dividido en dos, porque Secure Enclave exige dispositivo:**

*Parte A, en simulador y CI (lógica pura, con clave de software tras la misma interfaz):*
- SHA-256 en streaming de un archivo de 1 GB coincide con `shasum -a 256` del sistema, y el
  pico de memoria del proceso se mantiene bajo un umbral declarado (esto prueba que
  efectivamente es streaming y no lectura completa).
- Manifiesto ordenado de forma estable ante orden de descubrimiento distinto en el sistema
  de archivos.
- **Detección de manipulación, tres casos:** alterar 1 byte de `mesh.ply` → falla y
  **señala el archivo específico**; borrar un sello intermedio de la cadena → falla por
  `prevSealHash` roto e indica en qué eslabón; reordenar dos líneas de `chain.jsonl` → falla.
- Añadir un archivo nuevo no declarado en el manifiesto → falla (no solo se detectan
  modificaciones, también adiciones).
- WORM: intentar escribir en un directorio ya sellado devuelve error tipado.
- **Verificador externo:** `tools/verify_chain.py` reproduce el veredicto de
  `ChainVerifying` sobre los mismos bundles, incluidos los cuatro casos de manipulación,
  **sin la app y sin Swift**. Si los dos verificadores discrepan en algún caso, la fase no
  está terminada.

*Parte B, en dispositivo físico:*
- La firma se genera con clave de Secure Enclave, requiere Face ID, y verifica contra la
  clave pública **almacenada dentro del propio sello** (no en el llavero) — de modo que un
  sello siga siendo verificable aunque la clave se pierda.
- Cancelar Face ID deja el registro **sin sellar** y en estado explícito, nunca sellado a
  medias.
- Cambiar la biometría inscrita del dispositivo invalida la clave: los sellos anteriores
  siguen verificando, y los nuevos se firman con una clave nueva registrada en el sello.
  Este comportamiento se prueba y se documenta; es un riesgo operativo real en terreno.
- `VERIFY.txt` incluido en cada bundle permite a una persona ajena reproducir la
  verificación siguiendo solo ese texto.

**Depende de:** F9.
**Capacidades:** 4 (cadena de custodia antes/después).
**Riesgos que mitiga:** límites reales de la custodia sin backend — se documenta
explícitamente en `VERIFY.txt` que esto prueba **integridad + dispositivo + biometría**, y
que **no prueba tiempo absoluto** (el reloj del dispositivo es manipulable) **ni ausencia de
manipulación física previa a la captura**; pérdida de la clave por cambio de biometría o de
teléfono.
**Archivos principales:** `Custody/Hasher.swift`, `Custody/SealSigner.swift`,
`Custody/ChainVerifier.swift`, `tools/verify_chain.py`, plantilla `VERIFY.txt`.

---

### Fase 11 — `Registration/`: inicialización en cascada, ICP con chequeo de degeneración y diff

**Qué hacer:** cascada de inicialización (objetivos de control físicos `ARReferenceImage` >
landmarks manuales > geodésico + gravedad), `Capture/ControlTargetDetector`, ICP
punto-a-plano recortado, `DegeneracyCheck` (número de condición del Hessiano), máscara de
región estable para excluir la zona de cambio esperado, `DiffEngine` (distancia firmada,
clusters, volumen ganado/perdido).

**Es la fase más compleja y riesgosa del proyecto. Su presupuesto de horas es el mayor y su
criterio de aceptación el más exigente.**

**Criterio de aceptación — verdad sintética antes de cualquier prueba de campo:**
- Dos copias de una malla con transformación rígida conocida (traslación 0.85 m, rotación
  12.7°) más ruido de 3 mm → transformación recuperada dentro de 1 mm y 0.1°.
- Convergencia desde inicialización mala (20° de error inicial) y **no convergencia
  declarada** desde una inicialización imposible (120°): en el segundo caso devuelve error,
  no un mínimo local disfrazado de éxito.
- **Test de degeneración:** escena que es un solo plano (pared lisa, el caso real de un
  corte estratigráfico) → `DegeneracyCheck` detecta el número de condición sobre el umbral y
  **el sistema se niega a reportar diff**. El test falla si el ICP devuelve cualquier
  resultado. Repetir con un cilindro (degeneración rotacional en un eje) y con una esquina
  bien condicionada, que **sí** debe pasar.
- **Test que protege el caso legal — el más importante de la fase:** pared sintética con un
  nicho excavado de volumen conocido. Se corren dos alineaciones: (a) sin máscara, incluyendo
  la zona cambiada → el volumen perdido reportado se subestima en más del 30%, y el test
  **afirma esa subestimación**; (b) con máscara de región estable → volumen perdido
  recuperado dentro de 3%. Este par de asserts es la prueba escrita de por qué existe la
  máscara, y detecta cualquier regresión futura que la elimine "para simplificar".
- Clustering del diff: cambios sintéticos en 3 zonas separadas → exactamente 3 clusters con
  volumen individual dentro de 5%; cambios por debajo del piso de ruido declarado **no**
  generan cluster.
- El diff reporta siempre volumen ganado y perdido por separado, más el piso de ruido usado
  como umbral.
- **En dispositivo:** `ControlTargetDetector` reconoce un objetivo impreso a 2 m con
  iluminación normal y devuelve su pose; con el objetivo ausente, la cascada degrada a
  landmarks manuales y **lo declara en el resultado** (`initializationMethod`), de modo que
  el informe diga con qué se alineó.

**Depende de:** F2, F4; la parte de objetivos de control depende de F3.
**Capacidades:** 7 (monitoreo de yacimientos), 5 (daños con escaneo previo, caso no
inferido).
**Riesgos que mitiga:** degeneración geométrica del ICP en paredes planas; "alinear sobre la
zona que cambió anula el diff"; deriva de ARKit entre campañas separadas por meses.
**Archivos principales:** `Registration/ICP.swift`, `Registration/DegeneracyCheck.swift`,
`Registration/StableRegionMask.swift`, `Registration/DiffEngine.swift`,
`Capture/ControlTargetDetector.swift`.

---

### Fase 12 — `Export/`: siete formatos, byte-determinismo y sidecar obligatorio

**Qué hacer:** escritores de PLY binario, STL binario (1 unidad = 1 mm), USDZ vía ModelIO,
LAS 1.4 con VLR OGC WKT, GeoJSON/KML, CSV e informe PDF/A, más el sidecar `record.json`
obligatorio en todos.

**Criterio de aceptación — cada formato validado con una herramienta externa, no con el
propio código:**
- **Byte-determinismo:** exportar dos veces la misma escena produce archivos con SHA-256
  idéntico, en todos los formatos. Cuidado con timestamps embebidos y con el orden de
  iteración de diccionarios: si un formato exige una fecha, se usa la fecha del registro, no
  `Date()`.
- **PLY:** abre en MeshLab/Open3D; conteo de vértices y caras coincide con el `Mesh` de
  origen.
- **STL:** cubo de 100 mm exportado → bounding box leído por una herramienta externa
  (numpy-stl o el laminador) da 100.0 ± 0.001 en unidades del archivo. **El factor de escala
  es el error clásico de este formato** y merece su propio test.
- **USDZ:** abre en Quick Look en el dispositivo y en macOS; las dimensiones en metros
  coinciden con el origen.
- **LAS 1.4:** valida con `laspy`/PDAL sin advertencias; el WKT del VLR corresponde
  exactamente al EPSG declarado en el sidecar; las coordenadas reproyectadas con GDAL
  coinciden con el `UTMCoordinate` original dentro de 1 mm.
- **GeoJSON/KML:** validan contra su esquema; el polígono cargado en QGIS cae en el lugar
  correcto.
- **PDF/A:** valida con veraPDF sin errores de conformidad; contiene el disclaimer legal
  fijo, la distinción explícita entre medido e inferido, y la banda de incertidumbre de cada
  medición.
- **Sidecar obligatorio por diseño:** la API del exportador devuelve el par (archivo,
  sidecar) o falla; **no existe una firma que permita exportar sin sidecar**. El test lo
  verifica intentando construir el llamado sin sidecar y comprobando que no compila o que
  devuelve error.
- Contenido del sidecar validado contra esquema: dispositivo, estadísticas de captura, geo
  completo (incluido el burst), algoritmos con versión + parámetros + **semilla**,
  mediciones con incertidumbre, bloque de custodia y disclaimer. Test que falla si algún
  campo obligatorio está vacío.
- **Perfil de export con ubicación degradada:** existe un modo de exportación para difusión
  pública en que la coordenada se redondea o se omite, y está marcado como tal en el
  sidecar (ver riesgos: publicar coordenadas exactas de un sitio arqueológico facilita el
  saqueo).

**Depende de:** F4 (`MeshCloser` para STL), F8 (CRS para LAS/GeoJSON), F9 y F10 (bloque de
custodia del sidecar).
**Capacidades:** 8 (réplicas STL), 9 (LAS/CSV), 3, 4, y el informe CMN que cierra las 9.
**Riesgos que mitiga:** volumen inferido presentado como medido en un documento oficial;
escala equivocada en réplicas físicas; exposición de la ubicación exacta de sitios
protegidos.
**Archivos principales:** `Export/*Writer.swift`, `Export/RecordSidecar.swift`,
`tools/check_exports.py`.

---

### Fase 13 — `Rendering/` completo: campo de color, superposiciones y picking

**Qué hacer:** completar `ScanRendering` con presentación de malla con campo de color
(confianza, distancia firmada del diff, clasificación de estrato), superposición de plano y
cajas orientadas, y picking sobre la malla.

**Criterio de aceptación:**
- Un diff sintético cargado desde archivo se visualiza con la escala de color correcta y una
  leyenda con unidades; los valores extremos no saturan la escala en silencio.
- El picking devuelve el punto 3D correcto dentro de 5 mm sobre una malla sintética con
  puntos de verdad conocida (test automatizable con toques simulados, no solo visual).
- Rotar/zoom sobre mallas de más de 1 millón de triángulos mantiene una tasa de refresco
  utilizable; si no, la decimación se aplica automáticamente y se indica en pantalla que se
  está viendo una versión simplificada.
- **La guarda de arquitectura sigue verde:** ningún tipo de dominio importa SceneKit; el
  único import está en `Rendering/`.

**Depende de:** F3, F4.
**Capacidades:** soporte visual de las 9; crítica para 2, 6 y 7 (donde el operador decide
sobre lo que ve).
**Riesgos que mitiga:** decisiones del operador tomadas sobre una visualización engañosa;
acoplamiento a SceneKit que bloquearía la migración a RealityKit.
**Archivos principales:** `Rendering/*.swift`.

---

### Fase 14 — `UI/`: las 9 capacidades cableadas end-to-end

**Qué hacer:** las pantallas SwiftUI de los nueve flujos, la guía de captura, la revisión y
ajuste manual (segmentación, límites de estrato, máscara estable), y el cierre con sellado.

**Criterio de aceptación — una demo por capacidad, sin intervención de desarrollador ni
consola:**
1. Registro 3D: escanear → guardar hallazgo con malla, escala y coordenadas → aparece en el
   listado.
2. Perfil estratigráfico: escanear un corte → orto-imagen → marcar límites → potencias con
   su banda de incertidumbre.
3. Georreferenciación: coordenada UTM con huso y EPSG visibles, más la calidad de la
   fijación y el número de fijaciones del burst.
4. Custodia: sellar antes y después de una intervención → cadena con dos eslabones que
   verifica en verde, y verifica también con `tools/verify_chain.py` fuera de la app.
5. Daños: volumen perdido con **etiqueta visual distinta** para medido vs. inferido. La UI
   no debe permitir confundirlos: test de usabilidad con una persona ajena que debe
   identificar cuál es cuál sin ayuda.
6. Rescate: 3 o más especímenes segmentados, ajustados a mano, con posición, orientación y
   relaciones espaciales.
7. Monitoreo: dos campañas de la misma zona → diff con clusters, o **negativa explícita a
   reportar** si `DegeneracyCheck` falla. Ambas salidas se demuestran.
8. Réplica: exportar STL e imprimir (o laminar) una pieza cuya dimensión medida coincide con
   la real dentro del error documentado.
9. Inventario: lista de especímenes con volumen, OBB y export CSV/LAS.

- Transversal: cada flujo sobrevive a interrupción de sesión AR (llamada entrante, bloqueo
  de pantalla) sin perder datos ya escritos.

**Depende de:** F5, F6, F7, F10, F11, F12, F13.
**Capacidades:** las 9, todas.
**Riesgos que mitiga:** que las capacidades queden implementadas pero no alcanzables por un
operador real.
**Archivos principales:** `UI/Screens/*.swift`.

---

### Fase 15 — Hardening: `Diagnostics/`, jornada de terreno y objetos grandes

**Qué hacer:** `Trace` con `os_signpost`, `QualityReport`, monitores térmico y de disco,
captura por teselas para objetos de más de 5 m, límites de duración de escaneo, perfilado con
Instruments.

**Criterio de aceptación:**
- **Jornada simulada de 4 horas continuas:** la app no crashea, el consumo de batería y de
  almacenamiento por escaneo se mide y se documenta, y se calcula cuántos escaneos caben en
  una jornada con el dispositivo real.
- Bajo `ProcessInfo.thermalState == .serious`, la app degrada la captura de forma declarada
  (baja frecuencia, avisa) en vez de morir.
- Con menos del umbral de disco libre, bloquea el inicio de un escaneo nuevo con un mensaje
  accionable, en vez de fallar a mitad de escritura.
- **Objeto de más de 5 m capturado por teselas:** las teselas se fusionan y el error de
  cierre (discrepancia en el solape entre teselas) se **mide y se reporta**, no se oculta.
- **Sol directo:** escanear la misma superficie en sombra y bajo sol directo de mediodía →
  se documenta la degradación medida (huecos, σ de residuos, cobertura). La UI advierte
  cuando detecta el patrón de saturación. En Chile este no es un caso de borde, es la
  condición normal de trabajo.
- Escaneo largo: se mide la deriva de ARKit cerrando un recorrido sobre sí mismo y
  comparando la posición inicial y final; se fija un límite operativo de duración/área a
  partir del dato medido.
- `QualityReport` marca automáticamente cualquier sesión que exceda los límites medidos
  arriba, y esa marca viaja al sidecar y al informe.

**Depende de:** F14.
**Capacidades:** las 9 (condiciona la validez de todas en terreno real).
**Riesgos que mitiga:** saturación del LiDAR con sol directo; deriva de ARKit en escaneos
largos; presión térmica y de memoria con objetos grandes; autonomía y almacenamiento en
jornada de campo.
**Archivos principales:** `Diagnostics/*.swift`, `Capture/TileManager.swift`.

---

### Fase 16 — Validación en terreno: medir el error real, no prometerlo

**Qué hacer:** ejecutar el protocolo de validación física, registrar cada corrida en
`docs/validation_log.csv` y producir el resumen. Es el equivalente directo de la Fase 4 de
StockIA (`VALIDATION.md`), ampliado a las capacidades que tienen una magnitud medible.

**Criterio de aceptación — se acepta el número que salga; lo inaceptable es no tenerlo:**

| Magnitud | Referencia física de verdad conocida | Repeticiones mínimas |
|---|---|---|
| Escala lineal | Barra o escalímetro calibrado de 1 m incluido en cada escaneo | 5 |
| Volumen positivo | Caja rígida de dimensiones medidas con huincha (2-3 lecturas por lado) | 5 |
| Volumen de cavidad | Material medido retirado de un montículo (N baldes de volumen interior conocido) | 3 |
| Potencia de estrato | Caja con capas de arena de colores de espesor medido (10 cm), cortada para exponer el perfil | 5 |
| Volumen de sólido cerrado | Objeto irregular por desplazamiento de agua (Arquímedes) | 3 |
| **Ensayo nulo de monitoreo** | Dos escaneos de la misma escena **sin cambio alguno** entre ellos | 5 |
| Recuperación de cambio | La misma escena tras retirar un volumen medido (ej. 2 L) | 3 |
| Sesgo GPS | Vértice geodésico o punto de coordenada publicada, si hay acceso | 3 |

- **El ensayo nulo es el más importante de la fase**, y no tiene equivalente en StockIA: si
  el sistema reporta volumen perdido donde no cambió nada, ese número es el **piso de ruido**
  del monitoreo, y ninguna detección por debajo de él puede afirmarse en un informe. Ese
  umbral pasa a ser una constante del sistema y aparece en cada informe de diff.
- Cada magnitud se mide **en sombra y bajo sol directo** por separado. Se reportan dos
  bandas, no un promedio.
- El error se documenta como banda por condición, con la condición explicitada (distancia de
  trabajo, cobertura, iluminación, tipo de material). Un error alto y **consistente** es un
  dato útil: revela sesgo sistemático corregible; un error variable indica cobertura o
  tracking.
- **Regla dura:** ninguna cifra de precisión aparece en la UI, en el informe PDF/A ni en el
  sidecar hasta que esta fase la haya medido. Hasta entonces, el campo dice "no validado".
- Validación de dominio: un arqueólogo o paleontólogo revisa un informe completo y confirma
  que es utilizable ante el CMN. Si no lo es, esta fase no está cerrada.

**Depende de:** F15.
**Capacidades:** las 9.
**Riesgos que mitiga:** precisión del LiDAR vs. exigencia centimétrica (se resuelve
midiendo, no asumiendo); sesgo del GPS (se documenta, no se corrige); sol directo;
sobreventa de precisión, que en un contexto pericial es un riesgo legal, no solo un problema
de expectativas.
**Archivos principales:** `docs/VALIDATION.md`, `docs/validation_log.csv`,
`tools/validate_reference.py`.

---

### Fase 17 — Paquete probatorio y verificación por un tercero

**Qué hacer:** cerrar el ciclo probatorio completo: bundle exportado, `VERIFY.txt`,
verificador externo, informe PDF/A y disclaimer legal fijo revisado.

**Criterio de aceptación:**
- **Una persona ajena al proyecto, en un computador sin la app instalada**, recibe el bundle
  exportado y verifica la cadena de custodia siguiendo únicamente `VERIFY.txt`, en menos de
  15 minutos y sin ayuda. Si necesita preguntar algo, `VERIFY.txt` está incompleto.
- Esa misma persona detecta correctamente un bundle manipulado que se le entrega mezclado
  con dos bundles íntegros, sin saber cuál es cuál.
- El informe PDF/A contiene, en lenguaje claro: qué prueba la firma (integridad del archivo,
  dispositivo, presencia biométrica en el momento del sellado) y **qué no prueba** (fecha
  absoluta confiable, ausencia de manipulación física antes de la captura, autoría
  profesional certificada).
- Cada medición del informe indica si es medida o inferida, con qué método y con qué banda
  de incertidumbre medida en F16.
- El bundle está excluido del respaldo automático si así se decidió (§6, punto 7) y esa
  decisión está escrita en el informe.

**Depende de:** F10, F12, F16.
**Capacidades:** 4 principalmente; cierra la validez documental de las 9.
**Riesgos que mitiga:** sobreestimación de lo que la cadena de custodia sin backend
realmente prueba.

---

## 4. Configuración inicial del proyecto Xcode (checklist de la Fase 0)

**Proyecto y firma**

1. Verificar compatibilidad de macOS con la versión vigente de Xcode; instalar (dejar
   15 GB+ libres).
2. Nuevo proyecto: template "App", Interface SwiftUI, Language Swift, con "Include Tests"
   activado.
3. **Bundle identifier definitivo desde el inicio** (ej. `cl.<organizacion>.paleoregistro`)
   — no cambiarlo después: cuota de 3 App IDs por ventana móvil de 7 días en cuenta
   gratuita.
4. Deployment target: fijarlo a la versión de iOS instalada en el iPhone de prueba, no dejar
   el valor por defecto del template.
5. Signing & Capabilities: "Automatically manage signing", Team = Apple ID (agregarlo antes
   en Xcode > Settings > Accounts).
6. En el iPhone: Ajustes > Privacidad y seguridad > Modo Desarrollador > activar > reiniciar
   > confirmar. Conectar por cable, desbloquear, aceptar "Confiar en este computador".
7. Primer `Cmd+R` probablemente falla por certificado no confiado: iPhone > Ajustes >
   General > VPN y gestión de dispositivos > Trust. Volver a ejecutar.
8. Recordatorio operativo: la firma gratuita expira a los 7 días; reconectar y correr desde
   Xcode la renueva. Hacerlo antes de cualquier salida a terreno, no durante.

**Capabilities**

9. **No activar background modes.** Analizado y descartado: ARKit no corre en segundo
   plano, la ubicación es solo "cuando se usa la app", y los modos innecesarios generan
   fricción en revisión de App Store. Para terminar escrituras y hashes si la app pasa a
   segundo plano a mitad de operación, usar `beginBackgroundTask` (no requiere capability);
   si más adelante hace falta re-hashear bundles grandes en diferido, evaluar
   `BGProcessingTask` como decisión separada y justificada.
10. Secure Enclave (P-256 vía `kSecAttrTokenIDSecureEnclave`) **no requiere capability** con
    firma automática. Definir la ACL con `.biometryCurrentSet` o `.biometryAny` — ver §6,
    tiene consecuencias operativas reales.
11. Protección de datos: usar `NSFileProtectionCompleteUntilFirstUserAuthentication` para el
    directorio de hallazgos. `CompleteProtection` haría ilegibles los archivos con el
    teléfono bloqueado y rompería el hashing en segundo plano.
12. `UIFileSharingEnabled = YES` y `LSSupportsOpeningDocumentsInPlace = YES`: la extracción
    del bundle probatorio por Finder/Archivos es un requisito legal del proyecto, no una
    comodidad.
13. `UIRequiredDeviceCapabilities` incluye `arkit`. **La presencia de LiDAR no es declarable
    por esta vía** — se comprueba en tiempo de ejecución con
    `ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)` y la
    app muestra un mensaje claro si el dispositivo no la soporta.

**Permisos de Info.plist — texto exacto en español que verá el usuario**

```
NSCameraUsageDescription
PaleoRegistro usa la cámara y el sensor LiDAR para escanear el hallazgo en 3D y
tomar fotografías de respaldo del registro.

NSLocationWhenInUseUsageDescription
PaleoRegistro usa tu ubicación solo mientras registras un hallazgo, para
georreferenciar el escaneo en coordenadas UTM y dejarlo documentado en el informe.

NSFaceIDUsageDescription
PaleoRegistro usa Face ID para firmar el sello de integridad del registro con la
clave protegida del dispositivo. Sin esta firma no se puede cerrar la cadena de
custodia.
```

Condicionales, agregar solo si el flujo correspondiente se implementa:

```
NSPhotoLibraryAddUsageDescription
PaleoRegistro guarda en tu fototeca las fotografías y los modelos exportados del
hallazgo.

NSMotionUsageDescription
PaleoRegistro usa los sensores de movimiento para estabilizar el seguimiento del
escaneo 3D.
```

**No agregar** `NSLocationAlwaysAndWhenInUseUsageDescription`: la arquitectura decidió
ubicación solo en uso, y pedir permiso permanente sin necesitarlo perjudica la aceptación
del permiso y la revisión.

**Guardas de build de determinismo (críticas, se fijan antes de la primera línea de
matemática)**

14. Optimización Release en `-O`, **nunca `-Ofast`**; sin `-ffast-math` ni
    `-funsafe-math-optimizations` en ninguna configuración; sin fast-math en shaders Metal
    si más adelante se agregan.
15. `SWIFT_STRICT_CONCURRENCY = complete`.
16. Fase de build que ejecuta `Scripts/check_module_boundaries.sh` y falla el build ante
    imports prohibidos.
17. El esquema corre los tests en **Debug y Release**: el determinismo numérico se rompe
    entre configuraciones con más facilidad de lo que parece, y aquí eso invalidaría hashes.

---

## 5. Estimación de esfuerzo y riesgos

### 5.1 Estimación de esfuerzo

Rangos de orden de magnitud, en horas puras de trabajo, no calendario. La incertidumbre es
alta y deliberada.

| Fase | Horas | Nota |
|---|---|---|
| F0 — Entorno y proyecto | 6-10 | Incluye guardas de build y textos de permisos |
| F1 — Domain y contratos | 10-16 | Barato en código, caro en decisiones; ahorra el doble más adelante |
| F2 — Geometry | 25-40 | RANSAC/MSAC genérico con restricción es la pieza fina |
| F3 — Capture + Rendering mínimo | 25-40 | Parseo de buffers `ARMeshGeometry` es lo más árido |
| F4 — Mesh | 20-35 | `MeshCloser` robusto es la mitad del presupuesto |
| F5 — Volume | 30-50 | Tres integradores + política de enrutado |
| F6 — Stratigraphy | 25-40 | Trigonometría de manteo + flujo de marcación |
| F7 — Segmentation | 25-40 | El ajuste manual cuesta más que el automático |
| F8 — Geo | 30-50 | Krüger orden 8 y Horn 2D, ambos con verdad externa |
| F9 — Persistence | 20-30 | El encoder canónico y `rebuildIndex()` concentran el riesgo |
| F10 — Custody | 25-40 | Incluye el verificador externo en Python |
| **F11 — Registration** | **45-70** | **La fase más riesgosa; sobrecosto probable, no sorpresa** |
| F12 — Export | 40-65 | Siete formatos + PDF/A + validadores externos |
| F13 — Rendering completo | 15-25 | |
| F14 — UI de las 9 capacidades | 50-80 | Nueve flujos, no uno |
| F15 — Hardening y jornada | 25-40 | Abierto por naturaleza |
| F16 — Validación en terreno | 30-50 | Dominado por logística y repeticiones, no por código |
| F17 — Paquete probatorio | 10-20 | |
| **Total** | **~450-750 h** | Rango amplio a propósito |

Señal de recalibración: usar el tiempo real de F2 y F3 (los dos primeros hilos con
dificultad genuina) para reestimar el resto. Si F11 se pasa del rango alto, es la fase donde
conviene reducir alcance de forma consciente — por ejemplo, exigir objetivos de control
físicos y no soportar el camino de landmarks manuales en la primera versión — antes que
recortar tolerancias o eliminar `DegeneracyCheck`.

### 5.2 Riesgos y dónde se mitigan

El detalle narrativo de cada riesgo está en §2.F; esta tabla lo mapea a la fase donde se
mitiga concretamente.

| Riesgo | Fase de mitigación | Mitigación concreta y verificable |
|---|---|---|
| Precisión LiDAR vs. exigencia centimétrica de potencia de estrato | F6, F16 | Banda de incertidumbre propagada por medición; ninguna cifra en UI hasta medirla contra caja de capas de espesor conocido |
| Deriva y sesgo del GPS del iPhone | F8 | Burst completo persistido, `FixQualityGate`, yaw por trayectoria (Horn) y no por brújula; test que prueba que ninguna magnitud métrica consume coordenada absoluta |
| Deriva de ARKit en escaneos largos | F3, F15 | Medición de cierre de bucle; límite operativo de duración/área derivado del dato; teselado; objetivos de control como anclas |
| Degeneración geométrica del ICP en paredes planas | F11 | `DegeneracyCheck` por número de condición; test que **exige el rechazo** en escena de un solo plano |
| Alinear sobre la zona que cambió anula el diff | F11 | Máscara de región estable; test pareado que afirma la subestimación >30% sin máscara y la recuperación ±3% con ella |
| Saturación del LiDAR con sol directo | F3, F15, F16 | Detección del patrón de saturación y aviso; degradación medida sombra vs. sol de mediodía documentada por separado |
| Determinismo numérico | F0, F2, F9, F12 | Banderas de compilador sin fast-math; RNG sembrado con prueba bit a bit; `Double` en acumuladores; byte-determinismo verificado por SHA-256 |
| Volumen inferido confundido con medido | F5, F12, F14 | `isInferred` obligatorio con test que falla si no se puebla; sidecar y PDF/A lo distinguen; prueba de usabilidad con persona ajena |
| Límites de la custodia sin backend | F10, F17 | `VERIFY.txt` declara qué prueba y qué **no** (sin tiempo absoluto confiable); verificación exitosa por un tercero sin la app |
| Pérdida de la clave de firma por cambio de biometría o de teléfono | F10 | Clave pública embebida en cada sello; sellos antiguos verificables aunque la clave se invalide; comportamiento probado, no supuesto |
| WORM no es real en iOS | F10, F17 | Se implementa a nivel de app y se declara honestamente en `VERIFY.txt` como control de la app, no del sistema operativo |
| Objetos de más de 5 m, presión térmica y de memoria | F15 | Captura por teselas con error de cierre medido; degradación ante `thermalState`; bloqueo por disco bajo antes de iniciar |
| Autonomía y almacenamiento en jornada de terreno | F15, F16 | Jornada simulada de 4 h con consumo medido y número de escaneos por jornada calculado |
| Escala equivocada en réplicas 3D impresas | F12 | Test del cubo de 100 mm verificado con herramienta externa |
| Publicar coordenadas exactas de un sitio protegido facilita el saqueo | F12 | Perfil de exportación con ubicación degradada, marcado como tal en el sidecar |
| SwiftData tratado como fuente de verdad por descuido | F9 | `rebuildIndex()` probado tras borrar el store; test que falla si un flujo legal lee del índice |
| Contratos incompatibles entre sesiones de LLM distintas | F1 | Todos los tipos y protocolos fijados en la Fase 1 antes de abrir hilos paralelos; guarda de arquitectura en el build |

---

## 6. Información faltante y decisiones abiertas

Se explicitan en vez de asumirse en silencio. Varias condicionan el alcance real de alguna
capacidad.

**Bloqueantes de capacidad**

1. **Objetivos de control físicos.** ¿El equipo de terreno va a fabricar, imprimir e
   instalar objetivos `ARReferenceImage` permanentes en los sitios a monitorear? Sin ellos,
   la cascada de inicialización de la Fase 11 degrada a landmarks manuales y **el monitoreo
   periódico pierde fiabilidad de forma material** para uso en el marco del artículo 31 de
   la Ley 17.288. Subpreguntas: material resistente a intemperie y radiación UV en zonas
   como el norte de Chile; tamaño y distancia de detección; y sobre todo, **¿instalar un
   hito físico en un monumento nacional requiere autorización previa del CMN?** Si la
   requiere, es un plazo administrativo que hay que iniciar antes de la Fase 11, no después.
2. **¿Existe escaneo previo para los casos de daño?** Si en la práctica nunca hay un
   "antes", entonces el 100% del volumen de daño reportado será **inferido**, y eso cambia
   el peso probatorio del informe. Conviene saberlo antes de la Fase 5 para dimensionar
   cuánto esfuerzo poner en los caminos de inferencia versus el camino con previo.
3. **Datum y sistema de referencia exigido.** La arquitectura fija EPSG 32718/32719/32712,
   que son WGS84/UTM. Si el CMN, la IDE Chile o el MNHN exigen **SIRGAS-Chile en una época
   específica**, la diferencia respecto de WGS84 no es despreciable y crece con el tiempo por
   deformación tectónica — Chile tiene desplazamientos significativos post-2010. Definir
   esto antes de la Fase 8; cambiarlo después implica rehacer conversiones y re-exportar.
4. **Validez pretendida del registro.** ¿Es un informe administrativo al CMN o un peritaje
   ante tribunal? Si es lo segundo, falta un sellado de tiempo confiable (TSA RFC 3161), que
   hoy no existe porque no hay backend, y probablemente falte **firma electrónica avanzada**
   conforme a la normativa chilena: la firma con Secure Enclave **no** es FEA. Esta
   respuesta puede agregar una fase completa.
5. **Formato exigido del informe al CMN.** ¿Hay plantilla oficial, campos obligatorios,
   vocabulario controlado? Condiciona el generador PDF/A de la Fase 12 y potencialmente el
   esquema de `Finding` y `Specimen` de la Fase 1 (por ejemplo, si se requiere
   compatibilidad con Darwin Core para las fichas del MNHN, eso afecta el modelo de dominio
   y es mucho más barato decidirlo en F1 que en F12).

**Decisiones técnicas pendientes**

6. **Política de la clave de firma:** `.biometryCurrentSet` (más estricta, se invalida al
   inscribir una biometría nueva) o `.biometryAny`. Y qué se hace cuando el perito cambia de
   teléfono: ¿se acepta que la cadena se corte y se abra una nueva, o hace falta un
   mecanismo de continuidad? Decidir antes de la Fase 10.
7. **Respaldo del bundle:** ¿se excluye de iCloud (`isExcludedFromBackup`) para no duplicar
   evidencia fuera del control de custodia, o se respalda para no perderla? Es una tensión
   real entre integridad de la custodia y riesgo de pérdida del dato.
8. **Modelo exacto de iPhone o iPad y versión mínima de iOS.** Determina el margen de RAM y
   el nivel de riesgo térmico de la Fase 15, y si el teselado de objetos grandes es opcional
   u obligatorio.
9. **Multi-operador y multi-dispositivo.** ¿Varias personas registrando en la misma
   campaña, con dispositivos distintos? Afecta el modelo de identidad de la cadena de
   custodia y la unicidad de los identificadores de hallazgo. Es más barato decidirlo en la
   Fase 1 que retrofitearlo.
10. **Tamaño típico del hallazgo y del yacimiento.** Define si el teselado es caso de borde
    o el caso normal.
11. **Conectividad en terreno.** Sin señal, la primera fijación GPS tarda mucho más sin
    A-GPS, y eso cambia el protocolo de captura del burst en la Fase 8.
12. **Cumplimiento de exportación de criptografía** (`ITSAppUsesNonExemptEncryption`).
    Depende del canal de distribución: App Store, ad-hoc, o Apple Business Manager.
    Responder antes de la primera distribución, no antes.
13. **Disponibilidad de un profesional del dominio** (arqueólogo o paleontólogo) para
    validar la Fase 16 y revisar el informe. Sin esta persona, la Fase 16 puede medir
    errores geométricos pero no puede certificar que el resultado sea utilizable ante el
    CMN, y la Fase 17 queda incompleta.
14. **Retención y sensibilidad de la ubicación.** ¿Quién puede ver las coordenadas exactas y
    por cuánto tiempo se conservan los bundles en el dispositivo? Es la contraparte de
    política del perfil de export degradado de la Fase 12.

---

## 7. Próximos pasos sugeridos

1. Resolver los puntos bloqueantes de §6 (especialmente 1, 2, 3 y 4 — cambian alcance de
   fases completas) antes de comenzar F8 y F11.
2. Ejecutar F0 y F1 primero, sin paralelismo (bloquean todo lo demás).
3. Abrir la Ola 2 (F2, F3, F4, F8, F9) en paralelo apenas F1 cierre, siguiendo el mapa de
   paralelismo de §3.
4. Usar el tiempo real de F2 y F3 para recalibrar la estimación de esfuerzo de §5.1 antes de
   comprometerse con un cronograma.

---

*Fuentes internas citadas: `StockIA/Mesh/GroundPlaneEstimator.swift`,
`StockIA/Volume/VolumeIntegrator.swift`, `StockIA/Processing/ScanProcessor.swift`,
`StockIA/Mesh/MeshMergeCore.swift`, `StockIA/Mesh/ROIFilter.swift`,
`StockIA/Capture/ARSessionManager.swift`, `PLAN.md`, `VALIDATION.md`,
`posibles_mejoras.md` — todos en este repositorio, usados como conocimiento de referencia,
no como dependencia de código.*
