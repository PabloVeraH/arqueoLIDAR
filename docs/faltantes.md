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
- [ ] **WORM real**: hoy solo se escribe `.sealed`; el directorio sellado no queda de solo
  lectura.
- [ ] **Sellar antes / después de una intervención**: hoy solo se sella al guardar un escaneo.
- [ ] **Reemplazar un escaneo** (`supersedes`): el modelo lo admite, la app no lo ofrece.
- [~] **Custodia entendible para el usuario** (2026-10-17): los errores de verificación
  ahora se leen como frases claras (`CustodyText`), con el detalle técnico plegado, y
  la ficha del hallazgo tiene un historial de sellos (`SealHistory`). Falta compilar y
  probar (M7).
- [ ] **Custodia física de la pieza** (traspasos, actas de entrega): fuera del plan v1.
  La app custodia el registro digital, no el objeto.
- [ ] **Prueba con un tercero** (Fase 17): persona ajena verifica solo con `VERIFY.txt` y
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

- [ ] `Diagnostics/` y `QualityReport` (hoy solo HUD de temperatura y disco).
- [ ] Captura por teselas para objetos > 5 m, con error de cierre reportado.
- [ ] Aviso de saturación por sol directo.
- [ ] Límite de duración por deriva de ARKit.
- [ ] Sobrevivir a interrupciones (llamada, bloqueo) sin perder datos escritos.

## 7. Validación en terreno (Fase 16)

- [ ] `docs/validation_log.csv` y `docs/VALIDATION.md`: caja de medidas conocidas,
  ensayo nulo de monitoreo, sombra vs. sol, sesgo GPS.
- [ ] Hasta tener esas cifras, la UI y el sidecar deben decir "no validado".
- [ ] Pruebas pendientes de `docs/registro_pruebas.md` (exportar y re-verificar, dos sellos
  encadenados, `verify_chain.py` en Mac, GPS denegado, sitios y borrado).

## Registro de avance

| Fecha | Ítem | Estado | Commit |
|---|---|---|---|
| 2026-10-17 | Inventario inicial | — | 21f8258 |
| 2026-10-17 | Firma v2, rotación declarada, chip seguro + Face ID/código, cancelar sin perder la malla | [~] sin compilar; falta prueba en iPhone | 3d63b17, fbe49da |
| 2026-10-17 | Volumen medido vs. inferido en la ficha; marcar objeto al capturar; incertidumbre de volumen en m³ (bug) | [~] sin compilar; falta prueba en iPhone | c0f48bd, 48c4570 |
| 2026-10-17 | Errores de custodia en palabras de terreno; historial de sellos | [~] sin compilar; falta prueba en iPhone | 4989ca7, 734b4de |
