# PaleoRegistro, explicado para alguien de terreno

## En una frase

PaleoRegistro es una **app para iPhone** que convierte el teléfono en una **libreta de campo 3D con valor de prueba**. Usa el sensor LiDAR (un "radar de luz" que traen los iPhone Pro y mide distancias con láser) para dejar registrado un hallazgo con forma, medidas y ubicación GPS. Además le pone un **sello que muestra si alguien alteró el registro después**. Está pensada para el aviso al Consejo de Monumentos Nacionales bajo la Ley 17.288 y funciona **sin internet**.

## Lo primero: en qué estado está

La app ya existe como proyecto de Xcode (`arqueoLidar.xcodeproj` y la carpeta `arqueoLidar/`) y tiene dos pestañas:

- **Terreno**: el flujo de trabajo real.
  1. Se crea el expediente de un hallazgo con su nombre, código de expedición, responsable y permiso CMN.
  2. Se escanea con la **cámara y el LiDAR**, viendo la malla 3D en vivo sobre la imagen, mientras el **GPS** registra todas sus lecturas. Un panel muestra si el seguimiento es bueno, la temperatura del teléfono y el espacio libre. Un botón "Medir ruido" indica cuánto tiembla la medición sobre una pared plana, en milímetros.
  3. Al guardar, el escaneo se **sella** automáticamente.
  4. El escaneo se puede **ver en 3D**: girar con un dedo y acercar con dos.
  5. Se puede **exportar** a PLY, STL, OBJ, LAS y GeoJSON y compartir los archivos.
  6. Se puede **verificar** la cadena de custodia desde la misma app.
  7. Se puede **eliminar** un expediente deslizando su fila, pero **solo si no pasa la verificación** (por ejemplo, una prueba fallida o un expediente sin escaneos). Un expediente íntegro es evidencia y la app no deja borrarlo.
- **Diagnóstico**: corre las pruebas de cada módulo en el teléfono, con datos de resultado conocido, para confirmar que los cálculos están bien.

**Importante:** la pestaña Terreno se escribió sin poder compilarla, porque se hizo en un computador Windows. Antes de usarla en un caso real, hay que compilarla en una Mac con Xcode y probarla en un iPhone Pro.

Dónde quedan los archivos en el iPhone, en la app Archivos → En mi iPhone → ArqueoLiDAR:

- `Findings/FND-…/`: el expediente sellado.
- `Exports/FND-…/`: las exportaciones. Están fuera del expediente para no alterar el sello.

---

## Cómo se usaría en terreno, y qué módulo entra en cada paso

Supongamos que una retroexcavadora encuentra un hueso grande en una obra:

| Paso en terreno | Módulo que trabaja |
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

Todos los módulos se apoyan en uno más: la **Estructura de Trabajo** (en el código se llama `Domain`), el vocabulario común.

---

## Los 11 módulos, uno por uno

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

**Qué hace:** el iPhone captura el objeto en muchos pedazos de "malla", una red de triangulitos que forma la superficie. Este módulo:

- **une** los pedazos en un solo modelo,
- **recorta** solo la zona de interés y descarta la carretilla, los árboles y las piernas del ayudante,
- **reduce** la cantidad de triángulos cuando hace falta,
- **cierra** los agujeros del modelo, por ejemplo la base que estaba apoyada en el suelo.

**Analogía:** es la limpieza del hallazgo con brocha antes de fotografiarlo.

**Para qué le sirve:** sin un modelo limpio y cerrado no se puede medir volumen ni imprimir una réplica.

### 4. Volume: cuánto material hay o cuánto falta

Tiene **tres formas de medir**. La app elige la adecuada según para qué se hizo el escaneo:

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

1. la app genera la orto-imagen de la pared (módulo Geometry),
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

Este es el **módulo legalmente más importante**.

**Qué hace:**

- Calcula una **huella digital** de cada archivo (un código llamado *hash*, de tipo SHA-256). Si se cambia un solo punto del modelo, la huella cambia por completo.
- **Firma** esa huella con fecha, hora, GPS y autor.
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
  - `verify_chain.py`: comprueba que el expediente no fue manipulado.
  - `check_utm.py`: revisa las coordenadas.
  - `check_exports.py`: revisa que los archivos exportados estén bien formados.
- **`Scripts/check_module_boundaries.sh`**: una revisión interna de orden del código. No le afecta a usted.
- **`Tests/`**: pruebas automáticas que comprueban que los cálculos dan lo esperado.
- **Documentos:**
  - `plan_lidar_arqueologico.md` es el plan completo.
  - `README.md` es la guía de instalación en Mac, escrita para no programadores.
  - `fixes.md` es una auditoría de errores (todos marcados como resueltos).
  - `docs/presentacion-pantallas.html` es una maqueta de las pantallas propuestas.

---

## Lo que todavía falta o tiene problemas

Lo que la pestaña Terreno **todavía no hace**:

1. **Firma con Face ID y el chip seguro del iPhone.** Hoy firma con una clave de software que se genera de nuevo cada vez que se abre la app. La cadena se puede verificar igual, pero como prueba de autoría es más débil de lo que pide el plan.
2. **Mediciones desde la pantalla.** Volúmenes, potencia de estratos, separación de especímenes y comparación entre dos campañas ya están programados y probados, pero todavía no tienen botones en la app.
3. **Norte verdadero.** El modelo 3D queda con la vertical correcta, pero su giro respecto del norte es arbitrario. Falta guardar el recorrido de la cámara para calcularlo con la traza GPS.
4. **Informe PDF, CSV de especímenes y fotos de respaldo.** El CSV ya existe en el núcleo, pero solo tiene sentido cuando haya especímenes separados.

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
