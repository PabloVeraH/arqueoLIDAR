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

- [ ] **Firma con Secure Enclave + Face ID** (Fase 10, parte B). Hoy `FieldStore` usa
  `SoftwareSigningKey()`, que se regenera en cada arranque: cada sesión firma con otra
  clave pública y no hay prueba de autoría.
- [ ] **Cancelar Face ID** deja el escaneo sin sellar, en estado explícito, nunca a medias.
- [ ] **Rotación de clave** (`keyRotation`): evento firmado por la clave nueva que declara
  la anterior, para cambio de teléfono o de biometría.
- [ ] **WORM real**: hoy solo se escribe `.sealed`; el directorio sellado no queda de solo
  lectura.
- [ ] **Sellar antes / después de una intervención**: hoy solo se sella al guardar un escaneo.
- [ ] **Reemplazar un escaneo** (`supersedes`): el modelo lo admite, la app no lo ofrece.
- [ ] **Prueba con un tercero** (Fase 17): persona ajena verifica solo con `VERIFY.txt` y
  distingue un bundle manipulado entre tres.
- `rfc3161Token` queda vacío por diseño (sin red). No es pendiente de v1.

## 2. Mediciones sin pantalla (Fase 14)

Solo se ejercitan en Diagnóstico (`ModuleSelfTests.swift`):

- [ ] **Volumen**: `VolumePolicy`, `CavityIntegrator`, sólido cerrado, con etiqueta visual
  distinta para **medido vs. inferido**.
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
| 2026-10-17 | Inventario inicial | — | — |
