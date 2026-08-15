# PaleoRegistro — Guía de instalación para Mac

Esta guía te explica, **paso a paso y sin tecnicismos**, cómo dejar funcionando
PaleoRegistro en una computadora Mac. Está pensada para una persona que **no es
programadora**: solo tienes que seguir los pasos en orden y copiar/pegar los
comandos cuando se indique.

> **Qué es PaleoRegistro:** una aplicación para iPhone que usa el sensor LiDAR
> del teléfono para registrar hallazgos arqueológicos y paleontológicos en 3D,
> con geolocalización y cadena de custodia (Ley 17.288, Chile).

---

## Antes de empezar: lo que necesitas

| Qué necesitas | Por qué |
|---|---|
| Una Mac (portátil o de escritorio) | Para instalar el programa que compila la app |
| 15 GB de espacio libre en el disco | El programa ocupa mucho espacio |
| Un iPhone con sensor LiDAR (iPhone 12 Pro, 13 Pro, 14 Pro, 15 Pro, o iPad Pro) | Es el teléfono donde corre la app |
| Un cable USB del iPhone a la Mac | Para conectar el teléfono a la computadora |
| Una cuenta de Apple ID (la misma que usas en el iPhone) | Para firmar la app y poder instalarla en tu teléfono |
| Conexión a internet | Para descargar programas |

---

## Parte 1 — Instalar Xcode (el programa necesario)

**Xcode** es el programa que Apple usa para crear aplicaciones de iPhone. Es
gratuito, pero grande.

### Paso 1.1 — Abrir la App Store

1. Haz clic en el ícono de la **App Store** (el que tiene una letra "A" azul).
   Suele estar en la parte inferior de la pantalla, en la barra de íconos.

### Paso 1.2 — Buscar Xcode

1. En el cuadro de búsqueda (arriba a la izquierda), escribe: `Xcode`
2. Presiona la tecla **Enter**.

### Paso 1.3 — Instalar Xcode

1. Haz clic en el botón **"Obtener"** (Get) y luego en **"Instalar"**.
2. Te pedirá tu contraseña de Apple ID. Escríbela.
3. **Espera.** La descarga puede tardar desde 20 minutos hasta varias horas,
   dependiendo de tu conexión. Puedes dejar la computadora trabajando sola.

> **Importante:** NO apagues la computadora ni cierres la tapa de la laptop
> mientras se descarga. Si lo haces, tendrás que empezar de nuevo.

### Paso 1.4 — Abrir Xcode por primera vez

1. Cuando termine la instalación, busca **Xcode** en la carpeta "Aplicaciones"
   o con la lupa (Spotlight, presiona `Cmd + Espacio` y escribe `Xcode`).
2. Ábrelo. La primera vez te preguntará si quieres instalar "componentes
   adicionales". Haz clic en **"Instalar"** y espera a que termine.
3. Cuando veas la ventana de bienvenida de Xcode, **ciérrala** (botón rojo
   arriba a la izquierda). Ya está listo.

---

## Parte 2 — Obtener el código del proyecto

El proyecto ya está escrito. Solo necesitas "traerlo" a tu Mac.

### Paso 2.1 — Si tienes el proyecto en un archivo o USB

1. Copia la carpeta completa llamada **`arqueoLidar`** a tu Mac (por ejemplo, a
   la carpeta **Documentos**).

### Paso 2.2 — Verificar que todo llegó

1. Abre el **Finder** (el ícono de la cara sonriente azul).
2. Navega a **Documentos** → **arqueoLidar**.
3. Deberías ver estas carpetas:
   - `PaleoRegistro` (la carpeta principal del código)
   - `App` (carpeta para la aplicación)
   - `Scripts` (scripts de verificación)
   - `tools` (herramientas de verificación)
   - `docs` (documentación)
   - `plan_lidar_arqueologico.md` (el plan del proyecto)

Si ves todo esto, ¡perfecto!

---

## Parte 3 — Crear el proyecto de la aplicación en Xcode

El código de la "lógica" (cálculos, mediciones, custodia) ya está hecho. Lo que
falta es crear el "contenedor" de Xcode que junta todo en una app instalable.

### Paso 3.1 — Crear un proyecto nuevo

1. Abre **Xcode**.
2. En el menú superior, haz clic en **File** → **New** → **Project…**
3. En la ventana que aparece, arriba, elige la pestaña **iOS**.
4. Selecciona la plantilla **App** (la primera opción, con un ícono de app).
5. Haz clic en **Next**.

### Paso 3.2 — Nombrar el proyecto

En la siguiente pantalla, llena así los campos:

| Campo | Qué escribir |
|---|---|
| Product Name | `PaleoRegistro` |
| Team | Tu Apple ID (si aparece la lista, elige el tuyo; si no aparece, haz clic en "Add Account…" e ingresa tu Apple ID) |
| Organization Identifier | `cl.mnh` (esto forma el identificador único de la app) |
| Interface | **SwiftUI** |
| Language | **Swift** |
| Storage | **None** |
| Include Tests | **SÍ** (marcar la casilla) |

Haz clic en **Next**.

### Paso 3.3 — Dónde guardarlo

1. Navega hasta la carpeta **Documentos** → **arqueoLidar**.
2. **NO** crees una subcarpeta nueva: guarda el proyecto directamente dentro de
   `arqueoLidar`. Xcode creará su propia carpeta llamada `PaleoRegistro`.
3. Haz clic en **Create**.

> Si Xcode te avisa que ya existe una carpeta con ese nombre, no importa: el
> código lógico (dentro de `PaleoRegistro/Sources`) está aparte. Verifica que
> no se hayan sobrescrito archivos; si tienes dudas, guarda una copia de la
> carpeta `PaleoRegistro` original en otro lado antes.

---

## Parte 4 — Conectar el código lógico (SPM) con la app

El código de medición vive en un "paquete" separado (SPM). Ahora lo conectamos.

### Paso 4.1 — Agregar el paquete local

1. En Xcode, a la izquierda, verás una barra con el nombre de tu proyecto
   **PaleoRegistro** (ícono azul de Xcode). Haz clic en él.
2. En la parte superior de la ventana principal, verás pestañas como
   **General**, **Signing & Capabilities**, **Build Phases**… Haz clic en
   **General**.
3. Busca la sección **"Frameworks, Libraries, and Embedded Content"**.
4. Haz clic en el botón **"+"** (más).
5. En la ventana que aparece, busca **"PaleoRegistro"** (o los paquetes
   `PaleoDomain`, `PaleoGeometry`, etc.). Si no aparecen, haz clic en
   **"Add Other…"** → **"Add Package Dependency…"** → elige **"Add Local…"** y
   navega hasta `Documentos/arqueoLidar/PaleoRegistro` y selecciona la carpeta.
6. Agrega el paquete.

### Paso 4.2 — Verificar que compila

1. Presiona las teclas `Cmd + B` (o menú **Product** → **Build**).
2. Espera. La primera compilación descarga dependencias y puede tardar varios
   minutos.
3. Si al final ves **"Build Succeeded"** (compilación exitosa) en la parte
   superior, ¡todo va bien!
4. Si ves errores en rojo, **no entres en pánico**: toma una captura de pantalla
   y compártela con el equipo técnico. No intentes arreglarlo tú mismo.

---

## Parte 5 — Configurar los permisos de la app

La app necesita permiso de cámara, ubicación y Face ID. Hay que declararlos.

### Paso 5.1 — Abrir el archivo de configuración

1. En la barra de la izquierda de Xcode, busca y haz clic en el archivo
   **`Info.plist`** (suele estar dentro de la carpeta del proyecto).

### Paso 5.2 — Agregar los permisos

Vas a agregar tres entradas. Para cada una:

1. Haz clic en el botón **"+"** (más) que aparece al pasar el mouse sobre una fila.
2. Escribe el "Key" exacto (columna izquierda) y su texto (columna derecha).

**Permiso 1 — Cámara:**

- Key: `NSCameraUsageDescription`
- Texto (copiar y pegar):
  > PaleoRegistro usa la cámara y el sensor LiDAR para escanear el hallazgo en 3D y tomar fotografías de respaldo del registro.

**Permiso 2 — Ubicación:**

- Key: `NSLocationWhenInUseUsageDescription`
- Texto:
  > PaleoRegistro usa tu ubicación solo mientras registras un hallazgo, para georreferenciar el escaneo en coordenadas UTM y dejarlo documentado en el informe.

**Permiso 3 — Face ID:**

- Key: `NSFaceIDUsageDescription`
- Texto:
  > PaleoRegistro usa Face ID para firmar el sello de integridad del registro con la clave protegida del dispositivo. Sin esta firma no se puede cerrar la cadena de custodia.

### Paso 5.3 — Permitir compartir archivos

La app debe poder copiar los "expedientes" (carpetas con el escaneo) a la Mac.

1. En el mismo `Info.plist`, agrega dos entradas más, de tipo **Boolean** (el
   valor será `YES`):

| Key | Valor |
|---|---|
| `UIFileSharingEnabled` | YES |
| `LSSupportsOpeningDocumentsInPlace` | YES |

Para agregar un valor booleano: al crear la entrada, en "Type" elige **Boolean**
y escribe `YES`.

---

## Parte 6 — Preparar tu iPhone

### Paso 6.1 — Activar el "Modo Desarrollador" en el iPhone

1. En tu iPhone, ve a **Ajustes** → **Privacidad y seguridad**.
2. Desplázate hasta abajo y toca **Modo Desarrollador**.
3. Activa el interruptor.
4. El iPhone te pedirá **reiniciar**. Acepta y espera a que vuelva a encender.
5. Al encender, te preguntará si quieres **activar el Modo Desarrollador**.
   Toca **Activar**.

### Paso 6.2 — Conectar el iPhone a la Mac

1. Conecta el cable USB entre el iPhone y la Mac.
2. En el iPhone, aparecerá un mensaje **"¿Confiar en este computador?"**.
   Toca **Confiar**.
3. Escribe el código del iPhone si te lo pide.

---

## Parte 7 — Instalar la app en tu iPhone

### Paso 7.1 — Elegir el dispositivo

1. En Xcode, en la parte superior de la ventana (cerca del botón de "play"),
   verás un menú desplegable con el nombre de un dispositivo. Haz clic y elige
   **tu iPhone** (debe aparecer en la lista).

### Paso 7.2 — Ejecutar

1. Haz clic en el botón de **"play"** (triángulo) en la esquina superior
   izquierda de Xcode.
2. Espera. La primera vez puede tardar unos minutos.
3. La app se instalará y abrirá sola en tu iPhone.

> **Si aparece un error de "certificado no confiable":**
> 1. En el iPhone, ve a **Ajustes** → **General** → **VPN y gestión de
>    dispositivos**.
> 2. Busca tu Apple ID y toca **Confiar**.
> 3. Vuelve a Xcode y presiona "play" de nuevo.

---

## Parte 8 — Ejecutar las pruebas automáticas

Las pruebas verifican que los cálculos (volumen, potencia de estrato,
geolocalización, cadena de custodia) son correctos.

### Paso 8.1 — Ejecutar las pruebas

1. En Xcode, presiona `Cmd + U` (o menú **Product** → **Test**).
2. Espera a que terminen. Verás una lista de pruebas con palomitas verdes (✓).
3. Si todas están verdes, el código está verificado.
4. Si alguna está en rojo, captura la pantalla y compártela con el equipo.

---

## Parte 9 — Probar que los expedientes se pueden extraer

### Paso 9.1 — Generar un escaneo de prueba

1. Abre la app en el iPhone.
2. Haz un escaneo de prueba (apunta a una mesa o pared durante unos segundos).
3. Guarda el hallazgo.

### Paso 9.2 — Extraer el expediente a la Mac

1. Conecta el iPhone a la Mac por USB.
2. En la Mac, abre el **Finder**.
3. En la barra lateral izquierda, haz clic en tu iPhone (sección "Ubicaciones").
4. Haz clic en la pestaña **Archivos**.
5. Verás la app **PaleoRegistro**. Haz clic en ella.
6. Arrastra la carpeta `Findings` a tu escritorio o a Documentos.

### Paso 9.3 — Verificar la cadena de custodia (opcional, para técnicos)

Si quieres comprobar que el expediente no fue manipulado:

1. Abre la app **Terminal** (búscala con `Cmd + Espacio`, escribe `Terminal`).
2. Escribe este comando (ajusta la ruta a donde guardaste la carpeta):

```
python3 /Users/tu_usuario/Documentos/arqueoLidar/tools/verify_chain.py "/ruta/a/Findings/FND-..."
```

Si dice `VERIFICACIÓN: OK`, el expediente es íntegro.

---

## Problemas comunes y soluciones

| Problema | Solución |
|---|---|
| "Xcode tarda mucho en descargar" | Es normal. Déjalo terminar. No cierres la tapa. |
| "No aparece mi iPhone en Xcode" | Desconecta y vuelve a conectar el cable. Confirma "Confiar" en el iPhone. |
| "Error de firma / certificado" | Ve a Ajustes → General → VPN y gestión → Confiar. |
| "La app no abre y se cierra" | En Xcode, presiona `Cmd + Shift + K` (limpiar) y luego "play" de nuevo. |
| "Modo Desarrollador no aparece en mi iPhone" | Debes tener el iPhone conectado a la Mac y haberlo abierto en Xcode al menos una vez. |
| "Firma gratuita expira" | La firma gratuita dura 7 días. Para renovarla, conecta el iPhone y abre la app desde Xcode de nuevo. Hazlo **antes** de salir a terreno. |

---

## Resumen rápido

1. Instalar Xcode (App Store).
2. Copiar la carpeta `arqueoLidar` a Documentos.
3. Crear proyecto Xcode (File → New → Project).
4. Agregar el paquete local.
5. Configurar permisos en `Info.plist`.
6. Activar Modo Desarrollador en el iPhone.
7. Conectar y ejecutar (botón "play").
8. Ejecutar pruebas (`Cmd + U`).

¡Eso es todo! Si algo no coincide con lo que ves en pantalla, **toma una
captura de pantalla** y compártela con el equipo técnico. No modifiques nada por
tu cuenta.
