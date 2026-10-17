# Validación en terreno (Fase 16)

**Regla del plan:** ninguna cifra de precisión aparece en la app, en el informe ni en
`record.json` hasta que este protocolo la haya medido. Hasta entonces dicen
"Precisión en terreno: no validada". Lo inaceptable no es un error grande: es no
tenerlo medido.

## Cómo se hace

Cada corrida es **un escaneo de algo cuyo valor real se conoce**, medido con la app y
anotado en `docs/validation_log.csv` (una fila por corrida). Cada magnitud se mide **a la
sombra y bajo sol directo por separado**: en Chile el sol es la condición normal y el
LiDAR pierde puntos con mucha luz.

| Magnitud (`magnitud` en la planilla) | Referencia de valor conocido | Corridas por condición |
|---|---|---|
| `escala_lineal` | Barra o escalímetro de 1 m dentro del escaneo | 5 |
| `volumen_positivo` | Caja rígida medida con huincha (2 o 3 lecturas por lado) | 5 |
| `volumen_cavidad` | Material retirado de un montículo (N baldes de volumen conocido) | 3 |
| `potencia_estrato` | Caja con capas de arena de colores de 10 cm medidos, cortada para ver el perfil | 5 |
| `volumen_solido` | Objeto irregular, volumen por desplazamiento de agua | 3 |
| `ensayo_nulo` | Dos escaneos de la misma escena **sin cambio alguno** (referencia = 0) | 5 |
| `recuperacion_cambio` | La misma escena tras retirar un volumen medido (ej. 2 L) | 3 |
| `sesgo_gps` | Vértice geodésico o punto de coordenada publicada (error en metros) | 3 |

**El ensayo nulo es el más importante.** Si el sistema ve un cambio donde no hubo ninguno,
ese valor es el **piso de ruido** del monitoreo: ninguna pérdida de material por debajo de
él se puede afirmar en un informe.

## La planilla `docs/validation_log.csv`

Columnas: `fecha, commit, magnitud, condicion, referencia, medido, unidad, distancia_m,
material, notas`.

- `condicion`: `sombra` o `sol`.
- `referencia`: el valor real (huincha, baldes, agua…). `medido`: lo que dio la app.
  Misma unidad en ambas (`m`, `m3`).
- `commit`: la versión de la app (Diagnóstico o `git log -1`).
- `distancia_m`, `material`, `notas`: a qué distancia se escaneó, sobre qué material y
  cualquier cosa rara (viento, polvo, cobertura incompleta).

Ejemplo de fila:

```
2026-10-20,48c4570,volumen_positivo,sombra,0.060,0.0624,m3,1.5,caja de cartón,3 pasadas
```

## Resumen

Se regenera con:

```bash
python3 tools/validate_reference.py --escribir docs/VALIDATION.md
```

Por magnitud y condición da el **sesgo** (error medio: si es alto pero constante, se puede
corregir), la **dispersión** y la **banda** (sesgo ± 2 desviaciones, donde cae ~95 % de las
mediciones). Una dispersión alta indica problemas de cobertura o de seguimiento, no del sensor.

<!-- resumen -->
| Magnitud | Condición | Corridas | Sesgo | Desv. | Banda (±2σ) | Error relativo | Estado |
|---|---|---|---|---|---|---|---|
| escala_lineal | sombra | 0/5 | — | — | — | — | sin datos |
| escala_lineal | sol | 0/5 | — | — | — | — | sin datos |
| volumen_positivo | sombra | 0/5 | — | — | — | — | sin datos |
| volumen_positivo | sol | 0/5 | — | — | — | — | sin datos |
| volumen_cavidad | sombra | 0/3 | — | — | — | — | sin datos |
| volumen_cavidad | sol | 0/3 | — | — | — | — | sin datos |
| potencia_estrato | sombra | 0/5 | — | — | — | — | sin datos |
| potencia_estrato | sol | 0/5 | — | — | — | — | sin datos |
| volumen_solido | sombra | 0/3 | — | — | — | — | sin datos |
| volumen_solido | sol | 0/3 | — | — | — | — | sin datos |
| ensayo_nulo | sombra | 0/5 | — | — | — | — | sin datos |
| ensayo_nulo | sol | 0/5 | — | — | — | — | sin datos |
| recuperacion_cambio | sombra | 0/3 | — | — | — | — | sin datos |
| recuperacion_cambio | sol | 0/3 | — | — | — | — | sin datos |
| sesgo_gps | sombra | 0/3 | — | — | — | — | sin datos |
| sesgo_gps | sol | 0/3 | — | — | — | — | sin datos |

**Validación incompleta:** la app debe seguir diciendo «no validada».
<!-- /resumen -->

## Cuándo se da por validado

Cuando todas las filas del resumen dicen **OK** (corridas suficientes en sombra y sol), y
además **un arqueólogo o paleontólogo revisa un informe completo y confirma que serviría
ante el CMN**. Recién entonces las bandas medidas pueden reemplazar "no validada" en la app.
