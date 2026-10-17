# Registro de pruebas en dispositivo

Bitácora de pruebas de la app en un iPhone Pro real. Cada entrada indica la
versión probada (commit), qué se hizo y qué resultó, con números cuando los hay.
Lo que no se probó se marca como pendiente, no como aprobado.

---

## 2026-10-14 · iPhone de Esteban (iOS 27.2) · Xcode 27 beta

### Versión `5120d7c` (captura de Esteban, antes de integrar el flujo de Pablo)

| Prueba | Resultado |
|---|---|
| Diagnóstico de módulos | ✅ 43/43 verificaciones |
| Captura LiDAR (wireframe + HUD) | ✅ 11 anclas, ~35 000 vértices en una pieza |
| Medir ruido (pared plana) | ✅ **σ = 0,9 mm a 1,59 m**, 218/218 vértices en el plano (100 %), radio 20 cm |
| Guardar y sellar | ✅ FND-F160C9C9: 31 279 vértices, 58 382 triángulos |
| Verificar integridad, expedientes sellados ANTES del arreglo de rutas | ❌ esperado: sus sellos tienen rutas `/private…` inválidas (bug ya corregido, ver abajo) |

Bug encontrado en esta prueba (solo se manifiesta en iPhone, no en los tests):
`Hasher.buildManifest` dejaba rutas como `/privatefinding.json` porque iOS entrega
Documentos como `/var/mobile/…` y el enumerador devuelve `/private/var/mobile/…`.
Corregido en `5120d7c` (y en paralelo por Pablo en `0d3722a`); quedó la versión con
`enumerator(atPath:)` y un test que lo reproduce con un enlace simbólico.

Primera medición con la versión anterior de "Medir ruido" (ajuste por mínimos
cuadrados sobre 30 cm): σ = 57,6 mm. No era ruido del sensor: la mira estaba sobre
un notebook y la zona mezclaba pantalla, teclado y mesa. Por eso la medición
ahora usa RANSAC y reporta qué fracción de puntos cae en el plano.

### Versión `157d8c1` (merge con el flujo de terreno de Pablo)

Compilación: el código de `7309f06` compiló **a la primera, sin errores ni
advertencias** de código en Xcode 27 beta (destino iPhone).

| Prueba | Resultado |
|---|---|
| Diagnóstico de módulos | ✅ 43/43 verificaciones |
| Pestañas Terreno / Diagnóstico | ✅ |
| Crear hallazgo ("Hueso de pollo", Cod001, FND-D820CF5D) | ✅ |
| Captura con GPS en interior | ✅ 37 lecturas, mejor ±11,5 m → marcado **GPS degradado** (umbral ±10 m), como se espera bajo techo |
| Ubicación guardada | -22,893015, -69,319865 |
| Guardar y sellar (propósito "Registro inicial") | ✅ 39 068 vértices, 72 715 triángulos |
| Visor 3D del escaneo | ✅ malla encuadrada, rota y hace zoom |
| Verificar expediente (1 escaneo) | ✅ **Íntegro: ningún archivo fue alterado desde el último sello** |
| Medir ruido | ⚠︎ en esta sesión solo se midió apuntando a zonas con objetos: "No se encontró un plano (noConsensus)", que es la respuesta correcta para una zona no plana. El mensaje queda visible hasta la siguiente medición |

### Pendiente (no probado todavía)

- Error del ICP en milímetros (Diagnóstico → Registration, abrir el detalle).
- Segundo escaneo en el mismo hallazgo y verificación con 2 sellos encadenados.
- Exportación (PLY, STL, OBJ, LAS, GeoJSON) y verificación posterior: debe seguir Íntegro.
- `tools/verify_chain.py` sobre un expediente real copiado a la Mac (OK y FALLO con 1 byte alterado).
- Escaneo de un objeto de medidas conocidas (caja) y comparación contra huincha.
- Prueba con GPS denegado.
- Expedientes de las 23:04, 23:06 y 23:15 quedaron con sellos inválidos (rutas
  rotas del bug ya corregido); se pueden borrar deslizando la fila en Terreno → Hallazgos.
- Eliminar: un expediente con sellos inválidos o sin escaneos debe borrarse tras
  confirmar; uno íntegro (p. ej. FND-D820CF5D) debe mostrar "No se eliminó" y seguir en la lista.
- Sitios: crear un sitio, crear un hallazgo dentro, escanear y verificar → debe dar Íntegro (ahora el expediente incluye `site.json`). Los hallazgos anteriores deben verse en "Hallazgos sin sitio".
- Sitios con GPS: crear un sitio y "Tomar ubicación con GPS" al aire libre → debe mostrar latitud, longitud y precisión; "sin ubicación" desaparece de la fila. Editar nombre/código y volver a tomar la ubicación.
- Eliminar sitio: uno sin hallazgos se borra tras confirmar; uno con hallazgos debe mostrar "No se eliminó".

### Pendiente: firma con chip seguro (commit de esta sesión, 2026-10-17)

Escrito en Windows, **sin compilar**. Primero en la Mac:
`cd PaleoRegistro && swift build && swift test` (suite nueva "firma v2 y rotación de
clave", 7 pruebas) y `python3 tools/test_verify_chain.py` (ya pasa en Windows: 7/7).

En el iPhone:

- Guardar un escaneo → debe pedir **Face ID**; la pantalla final dice "Firma: Chip seguro del iPhone".
- Cancelar Face ID → alerta "No se selló…", la malla sigue en pantalla y "Guardar" funciona otra vez.
  En Archivos no debe aparecer ninguna carpeta de escaneo nueva y el expediente debe seguir **Íntegro**.
- Fallar Face ID dos veces → debe ofrecer el código del iPhone, y con el código sí sella.
- Cerrar y abrir la app, sellar un segundo escaneo en el mismo expediente → en
  `seals/chain.jsonl` ambos sellos tienen el mismo `deviceKeyID` y el segundo no tiene `previousKeyID`.
- Un expediente sellado antes de este cambio (sellos v1), al agregarle un escaneo, debe seguir
  Íntegro; el sello nuevo lleva `"signatureVersion":2` y `previousKeyID` con la clave vieja.
- `verify_chain.py` en la Mac sobre ese expediente → OK.
- Simulador (sin chip seguro) → sella con "Clave de software (sin chip seguro)".
