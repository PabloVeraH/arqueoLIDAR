# Lo que falta por desarrollar

Inventario de pendientes contra `plan_lidar_arqueologico.md`, revisado el 2026-10-17
sobre `feat/arreglosEsteban`. Las 11 librerías de `PaleoRegistro` están programadas y
con tests; lo que falta es **conectarlas a la app** y **cerrar lo que solo se prueba en
un iPhone**. Marcar cada ítem al avanzar: `[ ]` pendiente, `[~]` en curso o sin probar
en dispositivo, `[x]` hecho y probado.

## 1. Cadena de custodia (Custody)

Ya funciona: SHA-256 por archivo y manifiesto, cadena `seals/chain.jsonl` con
`prevSealHash`, marca `.sealed`, `VERIFY.txt`, delta monótono entre sellos, verificador
en la app y `tools/verify_chain.py`.

- [~] **Firma con Secure Enclave + Face ID o código** (Fase 10, parte B).
  `arqueoLidar/Findings/SealingKeyStore.swift`: clave P-256 en el chip seguro, con
  `.userPresence` (Face ID **o código**, decisión del 2026-10-17: Face ID falla en terreno
  con lentes o casco). Sin chip seguro o sin código (simulador), clave de software
  persistente en el llavero, y el sello lo declara (`keyProtection = software`).
  Falta compilar y probar en el iPhone.
- [~] **Cancelar Face ID** no escribe nada: la autenticación se pide antes de guardar y la
  sesión AR se reanuda sin borrar la malla (`ScanController.resume`). Falta probar en el iPhone.
- [~] **Rotación de clave**: en vez de un evento aparte, el sello que firma con una clave
  nueva declara la anterior en `previousKeyID`, dentro de lo firmado. `ChainVerifier` y
  `verify_chain.py` rechazan un cambio de clave no declarado. Límite: lo firma solo la clave
  nueva (la vieja suele estar perdida), así que no prueba continuidad del operador.
- [~] **Firma v2** (hueco encontrado el 2026-10-17): la firma v1 cubría solo
  `rootHash|ms|autor`. Se podía borrar un sello intermedio y corregir el `prevSealHash`
  del siguiente sin romper ninguna firma. La v2 firma índice, prevSealHash, keyID,
  protección y rotación. Los sellos v1 siguen verificando. No se acepta un v1 después
  de un v2. Pruebas: suite `SealV2Tests` (Swift, sin correr aún) y
  `tools/test_verify_chain.py` (7/7 en Windows).
- [ ] **Recortar el final de la cadena** (quitar los últimos sellos y sus escaneos) no se
  detecta sin un ancla externa (copia entregada, TSA). Es un límite conocido; se
  documenta, no se resuelve en v1.
- [~] **WORM real** (2026-10-17): tras cada sello, los archivos del manifiesto quedan en
  0444 y las carpetas de escaneo en 0555 (`BundleWriter.lockSealed`). Borrar un
  expediente no íntegro primero devuelve los permisos. Es prevención, no reemplaza la
  verificación. Falta probarlo en el iPhone (M12).
- [~] **Sellar antes / después de una intervención** (2026-10-17): botón «Sellar estado
  actual» en la ficha del hallazgo. Guarda `notes/NOTE-….json` (momento + nota) y lo
  sella con Face ID y el GPS del momento. Aparece en el historial. Falta probarlo (M10).
- [~] **Reemplazar un escaneo** (2026-10-17): «Reemplazar este escaneo» en la ficha del
  escaneo abre la captura. El nuevo lleva `supersedes` y un motivo obligatorio
  (`supersedesReason`). El anterior sigue sellado y se marca "Reemplazado por…". Falta
  probarlo (M11).
- [~] **Custodia entendible para el usuario** (2026-10-17): los errores de verificación
  ahora se leen como frases claras (`CustodyText`), con el detalle técnico plegado, y
  la ficha del hallazgo tiene un historial de sellos (`SealHistory`). Falta compilar y
  probar (M7).
- [ ] **Custodia física de la pieza** (traspasos, actas de entrega): fuera del plan v1.
  La app custodia el registro digital, no el objeto.
- [~] **VERIFY.txt suficiente para un tercero** (2026-10-17): dos niveles. Nivel A:
  `shasum -a 256 -c seals/SHA256SUMS`, sin instalar nada. Nivel B:
  `python3 seals/verify_chain.py .`, con firmas. La app copia el verificador a `seals/`
  en cada sello. Falta probarlo en Mac (M8).
- [~] **Hora del GPS en el sello y firma v3** (2026-10-17): `gnssTime` toma la hora de la
  lectura GPS del sello. La firma v3 cubre el sello entero: antes, la ubicación y la hora
  del último sello se podían editar sin romper la firma. La versión de firma nunca baja
  dentro de una cadena. Falta probarlo en Mac (M9).
- [~] **Prueba con un tercero** (Fase 17): preparada. `tools/preparar_prueba_tercero.py`
  arma los tres expedientes (uno alterado, con autocomprobación) y
  `docs/prueba_tercero.md` es la guía para quien la dirige. Falta hacerla con una
  persona real (M13). Criterio: persona ajena verifica solo con `VERIFY.txt` y
  distingue un bundle manipulado entre tres.
- `rfc3161Token` queda vacío por diseño (sin red). No es pendiente de v1.

## 2. Mediciones sin pantalla (Fase 14)

Solo se ejercitan en Diagnóstico (`ModuleSelfTests.swift`):

- [~] **Volumen medido vs. inferido en la ficha** (2026-10-17): se marca el objeto al
  capturar, se ajusta una caja en el visor, `VolumeMeasurer` decide medido/inferido y la
  medición se sella en `measurements/`. Falta compilar y probar en el iPhone (M5, M6).
  Quedan fuera: cavidad contra un escaneo previo (necesita ICP, sería MEDIDO), simetría,
  caja girada (hoy alineada a los ejes de la captura) y tocar la malla para ubicarla.
  Riesgo conocido: las mallas de ARKit tienen muchos huecos, y tapar todos los bordes
  (`MeshCloser`) puede fallar en el sólido cerrado. Se verá en M6.
- [ ] **Estratigrafía**: orto-imagen (`Rectifier`), marcar límites con el dedo
  (`StratumBoundaryPicker`), potencia (`ThicknessCalculator`).
- [ ] **Especímenes**: `MeshSegmenter`, `ManualSegmenter` (dividir/unir),
  `SpatialRelationBuilder`, CSV de inventario.
- [ ] **Monitoreo**: `ICPAligner` + `DiffEngine` (mapa de calor, negativa explícita si la
  alineación es degenerada).
- [ ] **Limpieza de malla**: `ROIFilter` (recorte), `MeshCloser` (cierre de agujeros).

## 3. Georreferencia

- [ ] **Norte verdadero**: `TrackYawSolver` existe, pero la captura no guarda la
  trayectoria de la cámara.
- [ ] **Punto de control de topógrafo**: `SiteFrameResolver` sin conectar.
- [ ] **Orientación del sitio**: el sitio guarda el punto GPS, no su orientación.

## 4. Visor 3D completo (Fase 13)

- [ ] Campo de color (confianza, distancia del diff, estrato) con leyenda y unidades.
- [ ] Superposición de plano y cajas orientadas.
- [ ] Picking (tocar la malla → punto 3D), base de las mediciones manuales.
- [ ] Decimación automática sobre 1 M de triángulos, avisando que es versión simplificada.

## 5. Expediente e informe

- [ ] Notificación al CMN dentro del expediente (fecha, canal, folio).
- [ ] Informe PDF/A: qué prueba y qué no prueba la firma; cada medida medida/inferida
  con su banda de incertidumbre.
- [ ] Fotos de respaldo (p. ej. huincha cuando la potencia es poco confiable).

## 6. Robustez (Fase 15)

- [~] **Informe de calidad por escaneo** (2026-10-17): `QualityReport` (Domain), guardado y
  sellado como `quality.json`: duración, recorrido, interrupciones, seguimiento limitado,
  sol y temperatura, con advertencias en palabras. Se muestra en la ficha del escaneo.
  Los límites son **provisorios** (`QualityLimits.provisional`) hasta M14.
- [~] **Interrupciones**: aviso en la captura y conteo. ARKit intenta reubicarse sin borrar
  la malla (`sessionShouldAttemptRelocalization`). Si un guardado se cortó, lo no sellado
  se aparta a `Recuperados/` al abrir el hallazgo (`SealHistory.unsealedItems`) y el
  expediente sigue íntegro.
- [~] **Sol directo**: aviso cuando la confianza de profundidad cae y la luz es alta.
  Umbrales sin calibrar (`ScanController.sun…`).
- [~] **Límite de duración y recorrido**: tiempo y metros en el HUD, con aviso al superar el
  límite provisorio.
- [~] **Disco bajo**: con menos de 500 MB libres no deja guardar y explica qué hacer.
- [ ] **Captura por teselas (> 5 m)**: no se hizo. Medir el error de unión entre teselas
  necesita la deriva real de ARKit (M14); hacerlo antes sería inventar el número.
- Todo lo anterior falta compilarlo y probarlo en el iPhone (M15).

## 7. Validación en terreno (Fase 16)

- [~] **Protocolo listo** (2026-10-17): `docs/VALIDATION.md` (qué medir, con qué referencia
  y cuántas veces, en sombra y al sol), la planilla `docs/validation_log.csv` y
  `tools/validate_reference.py`, que calcula sesgo, dispersión, banda ±2σ y el piso de
  ruido del ensayo nulo, y escribe el resumen. Falta **hacer las corridas** con el iPhone
  (M14).
- [x] La app y `record.json` dicen "Precisión en terreno: no validada" (volumen y aviso legal
  de cada exportación).
- [ ] Pruebas pendientes de `docs/registro_pruebas.md` (exportar y re-verificar, dos sellos
  encadenados, `verify_chain.py` en Mac, GPS denegado, sitios y borrado): están en la cola
  de `pendientes_mac.md`.

## Registro de avance

| Fecha | Ítem | Estado | Commit |
|---|---|---|---|
| 2026-10-17 | Inventario inicial | — | 21f8258 |
| 2026-10-17 | Firma v2, rotación declarada, chip seguro + Face ID/código, cancelar sin perder la malla | [~] sin compilar; falta prueba en iPhone | 3d63b17, fbe49da |
| 2026-10-17 | Volumen medido vs. inferido en la ficha; marcar objeto al capturar; incertidumbre de volumen en m³ (bug) | [~] sin compilar; falta prueba en iPhone | c0f48bd, 48c4570 |
| 2026-10-17 | Errores de custodia en palabras de terreno; historial de sellos | [~] sin compilar; falta prueba en iPhone | 4989ca7, 734b4de |
| 2026-10-17 | VERIFY.txt para un tercero: SHA256SUMS + copia de verify_chain.py en seals/ | [~] falta prueba en Mac (M8) | 537eabf |
| 2026-10-17 | Firma v3 (sello entero) + hora del GPS | [~] Python 12/12; Swift sin compilar (M9) | a3d347a |
| 2026-10-17 | Sellar estado actual antes / después de intervenir | [~] sin compilar (M10) | 0190923 |
| 2026-10-17 | Reemplazar un escaneo sin borrarlo | [~] sin compilar (M11) | e610b43 |
| 2026-10-17 | Archivos sellados de solo lectura (WORM) | [~] sin compilar (M12) | 6277e84 |
