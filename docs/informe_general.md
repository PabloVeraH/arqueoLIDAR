# PaleoRegistro, explicado para alguien de terreno

## En una frase

PaleoRegistro es una **app para iPhone** que convierte el teléfono en una **libreta de campo 3D con valor de prueba**. Usa el sensor LiDAR (un "radar de luz" que traen los iPhone Pro y mide distancias con láser) para dejar registrado un hallazgo con forma, medidas y ubicación GPS. Además le pone un **sello que muestra si alguien alteró el registro después**. Está pensada para el aviso al Consejo de Monumentos Nacionales bajo la Ley 17.288 y funciona **sin internet**.

Este informe tiene dos partes:

- **Parte 1 — Qué puede hacer con la app:** lo que usted ve y usa en terreno.
- **Parte 2 — Cómo funciona por dentro:** las librerías internas que hacen los cálculos. Usted nunca las abre; las usan las funciones de la Parte 1. Sirve a quien mantiene el código o a un perito que quiera saber cómo se obtuvo cada número.

---

# Parte 1 — Qué puede hacer con la app

Al abrir la app se ve directamente la lista de **Sitios**. No hay más pantallas que aprender: todo se recorre de lo grande a lo pequeño.

```
Sitios → Hallazgos del sitio → Ficha del hallazgo → Escaneo → Visor 3D y exportación
```

### 1. Sitios

- Se registra el **sitio** o yacimiento con nombre, código y su **punto GPS de referencia**. La app lo calcula combinando varias lecturas del GPS, no una sola.
- Deslizando la fila del sitio se puede **editar** o **eliminar**. Solo se elimina un sitio **sin hallazgos**.
- Los hallazgos creados antes de que existieran los sitios aparecen en "Hallazgos sin sitio".

### 2. Hallazgos

- Dentro de cada sitio se crea el **expediente** de cada hallazgo: nombre, código de expedición, responsable, institución y permiso CMN. El responsable se recuerda para el siguiente hallazgo.
- Cada expediente guarda una **copia sellada de la ficha del sitio**: al compartirlo se sabe dónde se hizo, aunque después se edite el sitio.
- Un expediente se puede **eliminar** deslizando su fila, pero **solo si no pasa la verificación** (por ejemplo, una prueba fallida o un expediente sin escaneos). Un expediente íntegro es evidencia y la app no deja borrarlo.

### 3. Captura LiDAR

- Se escanea con la **cámara y el LiDAR**, viendo la malla 3D en vivo sobre la imagen, mientras el **GPS** registra todas sus lecturas.
- Un panel muestra si el seguimiento es bueno, la temperatura del teléfono y el espacio libre.
- El panel muestra también el **tiempo y los metros recorridos**, y avisa si el escaneo se hace demasiado largo (el seguimiento se va desviando), si hay **mucha luz** (el sol directo hace que el LiDAR pierda puntos: conviene hacer sombra), si hubo una **interrupción** (llamada o bloqueo) o si queda **poco espacio** en el teléfono.
- Cada escaneo guarda un **informe de calidad** que se ve en su ficha: duración, recorrido y cualquier advertencia. Los límites son provisorios hasta las pruebas de terreno.
- Si la app se cierra mientras guarda, lo que no alcanzó a sellarse se aparta a la carpeta `Recuperados/` y el expediente sigue íntegro.
- **Norte verdadero:** mientras se escanea, la app guarda el recorrido de la cámara. Si se caminan unos 15 a 20 m al aire libre, lo compara con el GPS y calcula hacia dónde está el norte, sin usar la brújula (que falla cerca de maquinaria). La ficha del escaneo dice con qué margen, o por qué no se pudo.
- **Puntos de control del topógrafo:** en "Herramientas → Punto de control" se apunta la mira a una marca medida por un topógrafo y se escribe su coordenada UTM. Con dos marcas o más, el norte y la ubicación salen de ellas, con precisión de centímetros en vez de metros.
- El botón "Medir ruido" indica cuánto tiembla la medición sobre una pared plana, en milímetros.
- El botón **"Marcar"** deja anotado cuál es el objeto: se apunta la mira al hueso o pieza, se elige un radio aproximado (25 cm a 2 m) y queda guardado con el escaneo. Conviene escanear **solo el objeto y una franja de suelo alrededor**: todo lo que la cámara ve entra en el modelo.
- Al guardar se elige el **propósito** (registro inicial, monitoreo, evaluación de daño, rescate…) y el escaneo se **sella**. Antes de guardar, el iPhone pide **Face ID o su código**: la firma se hace con una clave guardada en el **chip seguro** del teléfono, que no se puede copiar. Si se cancela Face ID, no se guarda nada y el escaneo sigue en pantalla para volver a intentarlo. Si el GPS fue malo, queda marcado "GPS degradado" o "Sin GPS".
- Si el iPhone no tiene código configurado, igual se sella, pero con una clave común (sin chip seguro). La pantalla final y el propio sello lo indican, porque esa firma prueba menos.

- Si un escaneo salió mal, en su ficha se toca **"Reemplazar este escaneo"** y se hace uno nuevo, con un motivo obligatorio. El escaneo malo **no se borra**: sigue sellado y queda marcado "Reemplazado por…". Es como tachar con una línea en la libreta de campo y anotar al lado.

### 4. Visor 3D

- El escaneo guardado se puede **ver en 3D**: girar con un dedo y acercar con dos. Muestra también su ubicación y precisión.
- **"Colorear por altura"** pinta el modelo de azul (bajo) a rojo (alto), con una leyenda en centímetros. Si unos pocos puntos son muy extremos, quedan fuera de la escala y la leyenda dice qué porcentaje.
- En **Medir volumen**, tocar el modelo lleva la caja a ese punto. Después de calcular se ven el plano de referencia (en verde) y los colores según cuánto sobresale o falta cada punto respecto de ese plano.
- Si el modelo es muy grande, para verlo con fluidez se muestra una versión simplificada y se avisa. Las mediciones siempre usan el modelo completo.

### 5. Volumen

- En la ficha del escaneo, **"Medir volumen"** muestra el modelo con una **caja naranja** que parte en el objeto marcado. Se ajusta con deslizadores (posición y tamaño) para que rodee el objeto con un poco de suelo alrededor.
- La app elige el cálculo según el propósito del escaneo: montículo o zanja sobre el suelo (registro inicial, monitoreo), pieza completa (rescate, inventario) o material faltante (evaluación de daño).
- Cada número lleva una etiqueta que no se puede confundir:
  - **MEDIDO**: sale directo de la superficie escaneada.
  - **INFERIDO · estimación**: la app tuvo que suponer algo que no se ve. Por ejemplo, la cara del hueso apoyada en el suelo, o cómo era la superficie antes del daño. Debajo se escribe qué se supuso.
- Hasta que se hagan las pruebas de terreno con objetos de medida conocida, la app dice **"Precisión en terreno: no validada"** y no muestra un margen de error.
- Al guardar se pide Face ID o el código, y la medición queda **sellada** en el expediente (carpeta `measurements/`).

### 6. Exportar

- Genera **PLY, STL, OBJ, LAS y GeoJSON**, cada uno con su ficha técnica `record.json`, y permite compartirlos.
- Los archivos quedan en la app Archivos → En mi iPhone → ArqueoLiDAR → `Exports/`, **fuera** del expediente para no alterar el sello.

### 7. Verificar el expediente

- Comprueba la **cadena de custodia**: dice "Íntegro" o explica en palabras qué cambió, falta o sobra. Por ejemplo: "Se modificó el modelo 3D del escaneo «Registro inicial» del 14 oct 2026 después de sellarse". Un desplegable "Detalle técnico" guarda el dato exacto para un perito.
- **"Sellar estado actual"** deja un sello a propósito, sin escaneo nuevo: se elige el momento ("Antes de intervenir", "Después de intervenir" o "Control"), se escribe una nota (por ejemplo, "extracción del cráneo con yeso") y se confirma con Face ID. Si hay señal, el sello lleva la ubicación y la hora del GPS.
- El **historial de sellos** muestra cada sello con su fecha y hora, qué incorporó (apertura del expediente, escaneo nuevo, medición nueva), con qué clave se firmó y si hubo un cambio de clave (otro iPhone).
- Después de sellar, los archivos del escaneo quedan **de solo lectura** en el iPhone. Esto evita cambios por error; la verificación sigue siendo la prueba.
- Ojo: la custodia protege el **registro digital** (escaneos, GPS, fichas y mediciones). No sigue a la pieza física: quién la tiene o adónde se trasladó se documenta aparte, con las actas que pida el CMN.
- El expediente completo se puede compartir y verificar en un computador **sin la app** con `tools/verify_chain.py`.

### Lo que la app todavía no hace

1. **Probar la firma con chip seguro en un iPhone real.** Ya está programada (Face ID o código, y cambio de clave declarado), pero falta probarla en el teléfono (ver `docs/registro_pruebas.md`).
2. **Más mediciones desde la pantalla.** El volumen ya tiene pantalla (falta probarla en el iPhone). La potencia de estratos, la separación de especímenes y la comparación entre dos campañas están programadas y probadas, pero todavía no tienen botones. El daño todavía no se puede comparar contra un escaneo anterior de la pieza intacta (eso daría un valor MEDIDO en vez de inferido).
3. **Norte verdadero.** El modelo 3D queda con la vertical correcta, pero su giro respecto del norte es arbitrario. Falta guardar el recorrido de la cámara para calcularlo con la traza GPS. Por lo mismo, el sitio guarda su punto GPS pero no su orientación.
4. **Notificación al CMN** (fecha, canal, folio) dentro del expediente.
5. **Informe PDF, CSV de especímenes y fotos de respaldo.** El CSV ya existe por dentro, pero solo tiene sentido cuando haya especímenes separados.

**Importante:** buena parte de las pantallas se escribió sin poder compilarlas, porque se hizo en un computador Windows. Antes de usarlas en un caso real hay que compilarlas en una Mac con Xcode y probarlas en un iPhone Pro (ver `docs/registro_pruebas.md`).

Dónde quedan los archivos en el iPhone, en la app Archivos → En mi iPhone → ArqueoLiDAR:

- `Sites/`: las fichas de los sitios.
- `Findings/FND-…/`: el expediente sellado.
- `Exports/FND-…/`: las exportaciones.

---

# Parte 2 — Cómo funciona por dentro

Las funciones de la Parte 1 se apoyan en **11 librerías internas** (el paquete `PaleoRegistro`). Ninguna aparece en la app: son el motor.

Quien desarrolla puede comprobarlas en el iPhone con la pestaña **Diagnóstico**, que corre las pruebas de cada librería con datos de resultado conocido. Esa pestaña **solo aparece al instalar la app desde Xcode**; la versión que se entrega a los usuarios (TestFlight o App Store) no la muestra.

## Qué librería trabaja en cada función

| Función de la app | Librerías que usa |
|---|---|
| Sitios | Estructura de Trabajo, Geo |
| Hallazgos | Estructura de Trabajo, Persistence, Custody (para decidir si se puede borrar) |
| Captura LiDAR | Mesh, Geo, Geometry ("Medir ruido"), Persistence, Custody |
| Visor 3D | Mesh |
| Volumen | Volume, Mesh (recorte), Geometry (suelo), Persistence, Custody |
| Exportar | Export, Geo |
| Verificar el expediente | Custody |
| Estratos, especímenes, comparación (aún sin pantalla) | Volume, Stratigraphy, Segmentation, Geometry, Registration |

## Cómo se usarían en terreno

Supongamos que una retroexcavadora encuentra un hueso grande en una obra:

| Paso en terreno | Librería que trabaja |
|---|---|
| 1. Se recorre el hallazgo con el iPhone y se van juntando los "pedazos" del escaneo | **Mesh** |
| 2. La app registra dónde está, en coordenadas UTM | **Geo** |
| 3. Se identifica el suelo o la pared de corte | **Geometry** |
| 4. Se separa cada pieza (hueso 1, hueso 2…) | **Segmentation** |
| 5. Se miden volúmenes: pieza, zanja o material perdido | **Volume** |
| 6. Se mide la potencia de los estratos en la pared | **Stratigraphy** |
| 7. Se guarda todo en una carpeta ordenada | **Persistence** |
| 8. Se "sella" el expediente con fecha, hora y firma | **Custody** |
| 9. Meses después se vuelve a escanear y se compara | **Registration** |
| 10. Se exportan archivos para el informe, el museo o la impresión 3D | **Export** |

Todas se apoyan en una más: la **Estructura de Trabajo** (en el código se llama `Domain`), el vocabulario común.

---

## Las 11 librerías, una por una

### 1. Estructura de Trabajo (`Domain` en el código): el vocabulario común

**Qué es:** el diccionario de la app. Define qué es un *Yacimiento*, un *Hallazgo*, una *Sesión de escaneo*, un *Espécimen*, una *Medición* y un *Sello*.

**Analogía:** la ficha de registro estándar que usan todos en una excavación. Si todos llenan la misma ficha, nadie se confunde.

**Para qué le sirve a usted:** organiza la información como usted ya piensa:

```
Yacimiento
 └── Hallazgo (el expediente legal)
      ├── Escaneos (antes, después, monitoreo, daño, rescate…)
      │    ├── Especímenes
      │    ├── Mediciones
      │    └── Perfiles estratigráficos
      ├── Comparaciones entre escaneos
      └── Cadena de sellos
```

Una regla importante: **un escaneo sellado nunca se edita ni se borra**. Si salió mal, se hace uno nuevo que declara "este reemplaza al anterior". Es como no usar corrector en una libreta de campo: se tacha con una línea y se anota al lado.

### 2. Geometry: encontrar el plano y la caja

**Qué hace:**

- Encuentra **el plano del suelo** o **el plano de la pared de corte** dentro de la nube de puntos.
- Ajusta una **caja orientada** alrededor de cada pieza para obtener largo, ancho, alto y orientación.
- Genera una **orto-imagen**: una foto "aplanada" de la pared, sin deformación de perspectiva y con escala real en centímetros.

**Analogía:** es como poner la cuerda de nivel en la excavación y medir el hueso con una caja imaginaria a su alrededor.

**Para qué le sirve:** todas las medidas necesitan una referencia (¿altura respecto de qué?). La orto-imagen es la base para dibujar los estratos.

### 3. Mesh: armar y limpiar el modelo 3D

**Qué hace:** el iPhone captura el objeto en muchos pedazos de "malla", una red de triangulitos que forma la superficie. Esta librería:

- **une** los pedazos en un solo modelo,
- **recorta** solo la zona de interés y descarta la carretilla, los árboles y las piernas del ayudante,
- **reduce** la cantidad de triángulos cuando hace falta,
- **cierra** los agujeros del modelo, por ejemplo la base que estaba apoyada en el suelo.

**Analogía:** es la limpieza del hallazgo con brocha antes de fotografiarlo.

**Para qué le sirve:** sin un modelo limpio y cerrado no se puede medir volumen ni imprimir una réplica.

### 4. Volume: cuánto material hay o cuánto falta

Tiene **tres formas de medir**. La app elegirá la adecuada según para qué se hizo el escaneo:

| Método | Cuándo se usa | Ejemplo |
|---|---|---|
| **Campo de alturas** | Superficies como un terreno visto desde arriba | Montículo, zanja, balance de material removido en monitoreo |
| **Sólido cerrado** | Objetos con formas complicadas, socavaciones o aleros | Cráneo de ballena, colmillo de mastodonte. Para inventario y rescate |
| **Cavidad** | Daño: medir lo que *falta* | Mordida de la pala de una retroexcavadora en un hueso |

**Punto clave para un informe legal:** el método de cavidad muchas veces tiene que *estimar* cómo era la superficie original. La app marca esos resultados como **"inferidos"** y no como "medidos". Presentar una estimación como si fuera una medición es el mayor riesgo legal de esta parte.

También distingue entre **volumen expuesto** (lo que se ve y se midió) y **volumen total estimado** (lo que probablemente sigue enterrado). Eso es útil para planificar la extracción, el embalaje y el transporte.

### 5. Stratigraphy: perfiles estratigráficos

**Qué hace:** mide la **potencia** (espesor) de cada nivel en la pared de corte, además del **manteo/buzamiento** (inclinación y dirección).

**Cómo se usa:** el LiDAR **no ve** el cambio entre dos arcillas igual de duras, porque la diferencia es de color y textura, no de forma. Por eso:

1. la app genera la orto-imagen de la pared (librería Geometry),
2. **usted marca con el dedo** los límites entre estratos sobre esa imagen,
3. la app calcula el espesor **verdadero**, medido perpendicular a los estratos, y también el **aparente**.

**Para qué le sirve:** evita el error común de sobreestimar la potencia cuando los estratos están inclinados. Si la medida es poco confiable, la app pide respaldo fotográfico con huincha.

### 6. Segmentation: separar las piezas

**Qué hace:** cuando en un escaneo hay varios huesos, los separa en especímenes individuales y calcula las **relaciones espaciales** entre ellos: distancia, dirección (azimut), diferencia de cota y si se tocan.

**Regla de diseño:** *"la máquina propone, el humano decide"*. La app puede sugerir una separación automática, pero el especialista dibuja una caja alrededor de cada pieza y puede **dividir** o **unir** piezas a mano. Juntar dos huesos en un mismo espécimen sería un error grave en un registro legal.

**Para qué le sirve:** la tabla de relaciones es la "asociación espacial" que va al informe de rescate.

### 7. Geo: ¿dónde está?

**Qué hace:**

- Convierte el GPS del teléfono a **coordenadas UTM** (husos 18S y 19S para Chile continental y 12S para Isla de Pascua), siempre con el código EPSG declarado.
- **No toma una sola lectura del GPS.** Toma muchas y guarda la serie completa con su precisión. Un perito puede cuestionar un punto, pero le cuesta mucho más cuestionar una serie con su dispersión declarada.
- Si el GPS es malo (más de unos 10 m de error), marca el registro como **"georreferencia degradada"** y esa advertencia llega hasta el informe.
- Calcula hacia dónde queda el **norte verdadero** sin confiar en la brújula, que falla cerca de maquinaria o de rocas con magnetita. Para eso compara el recorrido que usted caminó con la traza del GPS.
- Acepta un punto de control entregado por un topógrafo con GPS diferencial. Así la precisión puede subir de unos ±5 m a unos ±2 cm.

**Importante:** la app deja escrito que **el GPS del teléfono no es un levantamiento topográfico**.

### 8. Persistence: la carpeta del expediente

**Qué hace:** guarda cada hallazgo como una **carpeta normal de archivos**, no dentro de una base de datos oculta:

```
FND-2026-0412-9f3a/
  finding.json      ← ficha del hallazgo (sitio, autor, permiso CMN)
  seals/chain.jsonl ← libro de sellos
  scans/…/mesh.ply  ← modelo 3D
  scans/…/measurements.json
```

**Analogía:** es la caja de archivo física del expediente.

**Para qué le sirve:** la carpeta se puede copiar a un computador y entregar a un perito, y se puede revisar **sin necesitar la app**.

### 9. Custody: la cadena de custodia

Esta es la **librería legalmente más importante**.

**Qué hace:**

- Calcula una **huella digital** de cada archivo (un código llamado *hash*, de tipo SHA-256). Si se cambia un solo punto del modelo, la huella cambia por completo.
- **Firma** esa huella con fecha, hora, GPS y autor, usando una clave que vive en el **chip seguro** del iPhone y que solo se usa tras Face ID o el código. La firma cubre también el número del sello y la huella del sello anterior: no se puede borrar un sello del medio sin que se note.
- Si cambia la clave (por ejemplo, un teléfono nuevo), el sello siguiente **declara cuál era la anterior**. Los sellos viejos siguen verificando, porque cada uno lleva su propia clave pública.
- Encadena los sellos: cada sello incluye la huella del anterior. Así no se puede insertar ni antedatar un sello sin que se note.

**Analogía:** es como un libro de actas foliado, donde cada página se firma y cita la página anterior. Si se arranca o se agrega una hoja, se detecta.

**Uso típico:** se sella **antes** de intervenir el hallazgo y **después** de intervenirlo.

### 10. Registration: comparar dos visitas

**Qué hace:** sirve para el **monitoreo de yacimientos y santuarios** (art. 31). Toma un escaneo de enero y uno de junio y:

1. los **superpone** con precisión, para lo cual conviene tener marcas fijas en el sitio,
2. produce un **mapa de calor** de dónde se ganó o perdió material,
3. calcula cuánto volumen cambió y dónde.

**Medida de seguridad:** si el lugar es demasiado "liso", como una pared plana, y no hay forma de superponer los escaneos con confianza, **la app se niega a dar un resultado**. Así evita acusar falsamente "remoción ilegal de material" por un error de alineación.

### 11. Export: los archivos de salida

Genera los formatos que cada destinatario realmente usa:

| Para quién | Formato |
|---|---|
| Perito o especialista (CloudCompare, MeshLab) | **PLY** |
| Impresión 3D de réplicas para museografía | **STL** (1 unidad = 1 mm) |
| Otros programas 3D | **OBJ** |
| SIG (QGIS, ArcGIS) | **LAS** y **GeoJSON** |
| Planilla de inventario del museo | **CSV** |
| **Siempre**, junto a cualquier archivo | `record.json`: una "ficha técnica" con el aparato, la precisión del GPS, los parámetros de cálculo y el sello |

La regla es que **cualquier número se pueda recalcular exactamente** a partir de la carpeta.

---

## Las carpetas de apoyo

- **`tools/`**: tres programas pequeños para revisar los resultados **desde fuera de la app**, de modo que un tercero pueda comprobarlos:
  - `verify_chain.py`: comprueba que el expediente no fue manipulado (`test_verify_chain.py` lo pone a prueba con expedientes adulterados a propósito).
  - `check_utm.py`: revisa las coordenadas.
  - `check_exports.py`: revisa que los archivos exportados estén bien formados.
  - `preparar_prueba_tercero.py`: arma la prueba en la que una persona ajena verifica tres expedientes, uno alterado a propósito, solo con `VERIFY.txt` (guía en `docs/prueba_tercero.md`).
- **`Scripts/check_module_boundaries.sh`**: una revisión interna de orden del código. No le afecta a usted.
- **`Tests/`**: pruebas automáticas que comprueban que los cálculos dan lo esperado.
- **Documentos:**
  - `plan_lidar_arqueologico.md` es el plan completo.
  - `README.md` es la guía de instalación en Mac, escrita para no programadores.
  - `fixes.md` es una auditoría de errores (todos marcados como resueltos).
  - `docs/presentacion-pantallas.html` es una maqueta de las pantallas propuestas.

---

## Arreglos recientes

Arreglos que ya están en esta rama (traídos de `dev`):

- el verificador interno de la app ya puede leer sus propios sellos,
- el verificador externo (`verify_chain.py`) reconstruye bien lo que se firmó y revisa la huella general del expediente,
- `check_utm.py` ahora compara contra el conversor real de la app,
- el PLY guarda colores y normales,
- el alineamiento entre campañas (ICP) bajó su error de 0,20 m a unos 2 mm,
- hay pruebas reales del flujo completo de principio a fin,
- además: la conversión de UTM a latitud y longitud, el cálculo de volumen en el monitoreo y la lectura de modelos 3D guardados.

## Glosario mínimo

- **LiDAR:** un sensor que mide distancias con pulsos de luz láser invisibles y genera puntos 3D.
- **Malla:** la superficie 3D formada por miles de triángulos pequeños.
- **UTM / EPSG:** el sistema de coordenadas en metros y el código que dice exactamente cuál se usó.
- **Hash:** la huella digital de un archivo. Si cambia un byte, cambia toda la huella.
- **Firma digital:** la prueba de que *este* dispositivo, o esta persona, selló *esta* huella.
