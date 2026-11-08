# laliga-cloudflare-toggle

> Tus webs usan Cloudflare y se caen cada vez que juega LaLiga? Este script lo arregla automaticamente.

Los ISPs espanoles bloquean IPs de Cloudflare durante los partidos de futbol. Si tu web usa el proxy de Cloudflare (nube naranja), **es inaccesible desde Espana** mientras dura el bloqueo.

Este script detecta los bloqueos en tiempo real y desactiva el proxy CDN automaticamente. Cuando el partido termina, lo reactiva. Sin intervencion manual.

---

## Como funciona

```
  Cada 5 min
      |
      v
 hayahora.futbol  ---->  Tus IPs bloqueadas?
      |                        |
     NO                       SI
      |                        |
  Todo OK              Quitar proxy CDN
                      (naranja -> gris)
                             |
                     Trafico va directo
                      a tu servidor
                             |
                    Cuando termine el
                    bloqueo, restaurar
                      proxy (-> naranja)
```

1. Consulta la API de [hayahora.futbol](https://hayahora.futbol/) para saber si hay bloqueo activo
2. Resuelve las IPs de **cada dominio** desde varios resolvers y comprueba si alguna esta bloqueada (ver abajo)
3. Si lo esta, desactiva el proxy **de ese dominio** via Cloudflare API (nube naranja -> gris)
4. Cuando el bloqueo de ese dominio termina y sigue libre durante `MIN_CLEAR_MINUTES` (15 por defecto), reactiva su proxy exactamente como estaba

### Deteccion de IPs (por que no basta con un `dig`)

Las IPs anycast compartidas de Cloudflare cambian segun el resolver y la ubicacion. Si el script corre fuera de Espana, un `dig` a secas puede devolver `188.114.96.2` mientras los usuarios de Movistar o DIGI reciben `188.114.96.5`, que es la que esta bloqueada. Por eso, para cada dominio el script reune un **conjunto de IPs candidatas** (solo IPs de Cloudflare, A y AAAA) con la union de:

- `dig` del sistema
- `dig @1.1.1.1`, `dig @8.8.8.8` y `dig @9.9.9.9`
- `dig @8.8.8.8 +subnet=<cidr>` con subredes de ISPs espanoles (EDNS Client Subnet): Movistar `80.58.0.0/16`, Vodafone `62.37.0.0/16`, Orange `90.160.0.0/16`, DIGI `79.116.0.0/16`, MasMovil `37.29.0.0/16`

Solo cuentan IPs dentro de los rangos publicados en [cloudflare.com/ips](https://www.cloudflare.com/ips/) (IPv4 e IPv6), con pertenencia exacta al prefijo: una IP de origen como `108.162.1.2` no es de Cloudflare aunque empiece igual que `108.162.192.0/18`.

Si el apex no da ninguna IP de Cloudflare (apex en gris o sin registro A/AAAA) pero tiene subdominios con proxy, el script toma como candidatas las IPs de esos subdominios: lista los registros con proxy de la zona dentro del dominio (sin comodines, como mucho 10 nombres) y resuelve cada uno con `dig` del sistema (A y AAAA) y `dig @8.8.8.8 +subnet` por ISP (A). Coste: como mucho 7 consultas por nombre y 70 por dominio, y una llamada mas a la API de Cloudflare, solo en ese caso.

Un dominio se considera **bloqueado** si alguna entrada de hayahora.futbol con estado actual `true` tiene una IP que:

| Regla | Condicion |
|---|---|
| `exact` | Esta en el conjunto de candidatas |
| `same24` | Esta en la misma /24 IPv4 que una candidata y dentro de los rangos de Cloudflare |
| `same48` | Esta en la misma /48 IPv6 que una candidata y dentro de los rangos de Cloudflare |

Cloudflare reparte IPs vecinas del mismo bloque, asi que un bloqueo en `.5` significa que tus usuarios pueden estar recibiendo `.5` aunque tu veas `.2`. El log indica que regla ha coincidido:

```
[WARN]   [exact] DIGI bloquea 188.114.96.5 (IP nuestra)
[WARN]   [same24] Movistar bloquea 188.114.97.5 (mismo bloque que nuestra 188.114.97.2)
```

La decision es **por dominio**: solo se desactiva el proxy de los dominios cuyo propio conjunto coincide, y cada dominio se reactiva cuando termina su propio bloqueo.

### Histeresis al rehabilitar (`MIN_CLEAR_MINUTES`)

hayahora.futbol a veces alterna entre ejecuciones las IPs vecinas de un mismo bloque (p.ej. `104.21.13.229` bloqueada en una consulta y no en la siguiente). Sin margen, el proxy entraria en un ciclo de quitar y poner cada pocos minutos. Por eso, cuando un dominio deshabilitado aparece libre, el script anota desde cuando lo esta y solo lo rehabilita cuando lleva `MIN_CLEAR_MINUTES` libre sin interrupcion:

```
[INFO]   Libre desde hace 5m, rehabilitando en 10m (MIN_CLEAR_MINUTES=15).
```

- Si el dominio vuelve a aparecer bloqueado, el contador se reinicia.
- `MIN_CLEAR_MINUTES=0` rehabilita en cuanto el dominio queda libre (comportamiento anterior).
- Si hayahora.futbol esta caida (o responde algo vacio o con otra forma) el contador se reinicia: solo cuentan comprobaciones libres seguidas con el feed sano. Mientras tanto manda el timeout de `MAX_DISABLED_HOURS`.
- En `DRY_RUN` solo se indica lo que haria, sin guardar nada.

## Caracteristicas

- **Deteccion precisa**: solo actua si las IPs de tus dominios concretos (o sus vecinas del mismo bloque de Cloudflare) estan bloqueadas, dominio a dominio
- **Crash-safe**: la intencion se guarda en el state *antes* de cada PATCH y se confirma despues; escritura atomica (temporal unico + mv)
- **Idempotente**: ejecutar multiples veces no causa cambios innecesarios
- **Multi-dominio**: gestiona todos tus dominios de Cloudflare a la vez
- **Notificaciones Telegram**: avisa cuando desactiva y cuando reactiva, sin repetir la alerta mientras el bloqueo sigue. Los mensajes que fallan se reintentan desde una bandeja de salida
- **Sin parpadeo**: espera `MIN_CLEAR_MINUTES` libre antes de reactivar el proxy
- **Lock atomico**: un directorio creado con `mkdir` impide ejecuciones concurrentes
- **Timeout de seguridad**: si hayahora.futbol se cae, restaura el proxy tras 12h maximo
- **Log acotado**: rota el log por tamano (`LOG_MAX_BYTES`)
- **DRY_RUN**: modo prueba para verificar sin tocar nada
- **Docker ready**: Dockerfile incluido para desplegar en Coolify, Railway, etc.

## Quickstart

```bash
git clone https://github.com/victorcavero14/laliga-cloudflare-toggle.git
cd laliga-cloudflare-toggle

cp .env.example .env
# Editar .env con tu token de Cloudflare y dominios

chmod +x toggle-proxy.sh
./toggle-proxy.sh
```

## Configuracion

### 1. Token de Cloudflare

1. Ve a [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
2. **Create Token** > plantilla **Edit zone DNS**
3. **Zone Resources**: selecciona tus zonas (o todas)
4. Copia el token

### 2. Zone IDs

En el panel de Cloudflare de cada dominio > **Overview** > barra lateral derecha > **Zone ID**

### 3. Variables de entorno (.env)

```bash
# Cloudflare
CLOUDFLARE_API_TOKEN="tu_token"
DOMAINS="zone_id_1:dominio1.com,zone_id_2:dominio2.com"

# Telegram (opcional)
TELEGRAM_BOT_TOKEN="bot_token"
TELEGRAM_CHAT_ID="-123456789"

# Opciones
DRY_RUN=false            # true = solo detecta, no toca nada (ni Cloudflare ni ficheros de state)
CHECK_INTERVAL=300       # segundos entre checks, 10-86400 (solo Docker)
MAX_DISABLED_HOURS=12    # maximo tiempo sin proxy si hayahora.futbol cae, 1-720
MIN_CLEAR_MINUTES=15     # minutos libre seguidos antes de rehabilitar, 0-10080 (0 = al momento)
```

Los numeros se leen en base 10 (`08` son 8) y deben estar en su rango; un valor invalido se avisa con `WARN` y se usa el valor por defecto. Los nombres (`DOMAINS`, `PROTECTED_DOMAINS`, registros) se comparan sin distinguir mayusculas y sin punto final.

El formato de `DOMAINS` es `ZONE_ID:DOMINIO` separados por comas, sin espacios obligatorios (se recortan): `DOMAINS="abc123:example.com,def456:example.org"`. El script gestiona el dominio y todos sus subdominios.

Variables opcionales adicionales:

```bash
PROTECTED_DOMAINS="cdn.example.com"   # nunca se les quita el proxy (separados por comas)
LOG_FILE=logs/toggle-proxy.log        # ruta del log
LOG_MAX_BYTES=5242880                 # rota el log al pasar de este tamano (0 = nunca)
STATE_FILE=state/proxy_disabled.json  # ruta del state file
HAYAHORA_API=https://hayahora.futbol/estado/data.json  # fuente de bloqueos (util para pruebas)
```

## Despliegue

### Cron (VPS / servidor)

```bash
crontab -e
```

```
*/5 * * * * /ruta/a/laliga-cloudflare-toggle/toggle-proxy.sh >> /ruta/a/laliga-cloudflare-toggle/logs/cron.log 2>&1
```

### Docker / Coolify

```bash
docker build -t laliga-cloudflare-toggle .
docker run -d \
  -e CLOUDFLARE_API_TOKEN="tu_token" \
  -e DOMAINS="zone_id:dominio.com" \
  -e DRY_RUN=true \
  -v laliga-state:/app/state \
  laliga-cloudflare-toggle
```

En **Coolify**: crear recurso Docker, apuntar al repo, configurar variables de entorno desde la UI, y anadir volumen persistente `/app/state`.

> **Importante**: el volumen `/app/state` debe persistir entre redeploys para que el script sepa que registros desactivo.

`docker stop` envia TERM al entrypoint, que lo reenvia a la comprobacion en curso, espera a que termine y sale con 0. Una llamada a Cloudflare puede tardar hasta 30 s, asi que conviene dar margen: `docker stop -t 45` (o `stop_grace_period: 45s` en Compose). Si aun asi se corta un PATCH, queda `pending` y la siguiente ejecucion lo reconcilia.

## Que registros DNS modifica

| Criterio | Valor |
|---|---|
| Tipos | A, AAAA, CNAME |
| Scope | Dominio configurado + todos sus subdominios |
| Condicion | `proxiable: true` y actualmente `proxied: true` |
| Cambio | Solo el campo `proxied` (`{"proxied": false}` / `{"proxied": true}`): nunca nombre, contenido ni TTL |
| Paginacion | Se leen todas las paginas de `dns_records` (`result_info.total_pages`, maximo 50) |
| Registros manuales en gris | Nunca se tocan |
| Registros de solo lectura (`meta.read_only`, p.ej. creados por un Worker) | Se saltan: Cloudflare no permite editarlos (error 1043) |

## Seguridad ante fallos

| Escenario | Comportamiento |
|---|---|
| Crash, timeout o fallo de log en mitad de un PATCH | Antes de cada PATCH el registro se guarda en el state como `pending`. La siguiente ejecucion lo comprueba con un GET: en gris se confirma (y se alerta); con proxy se descarta y, si sigue bloqueado, se vuelve a quitar; si ya no existe se descarta |
| Cloudflare rechaza un PATCH (4xx) | El registro no cambio: se retira del state y se registra el `errors` de la API |
| Crash mid-enable | Registros rehabilitados se borran del state uno a uno. Siguiente ejecucion retoma los pendientes |
| Restauracion parcial | Cada registro restaurado se cuenta y se alerta aunque otros del dominio fallen; la alerta indica cuantos siguen en gris |
| Registro eliminado en Cloudflare (404 / 81044) | Se da por resuelto, con una linea de log |
| Ejecucion concurrente | Lock atomico `state/toggle-proxy.lock.d` (con `mkdir`) y PID dentro. Se considera huerfano si el PID ya no existe o si tiene mas de 30 minutos |
| hayahora.futbol caido, HTTP de error, cuerpo vacio o con otra forma | Cuenta como feed no disponible: no toca nada (fail-safe), reinicia el contador de libre y, si el proxy lleva mas de `MAX_DISABLED_HOURS` desactivado, lo restaura por timeout |
| `disabled_at` ISO antiguo (`...Z`) | Se interpreta siempre como UTC, sin depender de `date` (GNU, BusyBox o BSD). Uno ilegible se registra como `ERROR` y se da por vencido: nunca espera para siempre |
| State de una version anterior | Los registros sin campo `domain` se asignan por nombre; un archivo de IPs antiguo (lista) se aplica a todos los dominios; sin archivo de IPs se usa el check amplio de Cloudflare |
| State u otro fichero JSON corrupto | Se mueve a `<fichero>.corrupt-<epoch>`, se registra como `ERROR` y se alerta por Telegram. Nunca se trata como vacio. Si era el state, el script ya no sabe que registros quito y **no los restaura solo**: revisa en Cloudflare los registros en gris de los dominios que indica la alerta y borra el `.corrupt` al terminar. Mientras exista, no se borran los ficheros de IPs ni de marcas de libre. Un fichero de IPs o de marcas corrupto no impide seguir restaurando el state |
| El log no se puede escribir (disco lleno, permisos) | No aborta la ejecucion: el state y las alertas siguen |
| Telegram rechaza un mensaje | `429`, `5xx` o error de red: va a la bandeja de salida y se reintenta al empezar la siguiente ejecucion respetando `retry_after`. Otros `4xx`: `ERROR` con la `description` y se descarta |
| hayahora.futbol alterna IPs vecinas | Histeresis: no rehabilita hasta `MIN_CLEAR_MINUTES` libre seguido |
| `docker stop` | El entrypoint reenvia TERM, espera a la ejecucion en curso y sale con 0 |

## Estructura

```
laliga-cloudflare-toggle/
├── toggle-proxy.sh      # Script principal
├── lib/ip-match.sh      # Funciones puras (rangos de Cloudflare, /24, /48, feed, fechas, numeros)
├── tests/
│   ├── run-all.sh               # Ejecuta todos los tests (bash del PATH y /bin/bash)
│   ├── test-ip-match.sh         # Tests unitarios de lib/ip-match.sh
│   ├── test-integration.sh      # Escenarios completos con curl/dig/date falsos
│   ├── test-entrypoint.sh       # Senales y CHECK_INTERVAL del entrypoint
│   └── integration/bin/         # Stubs de curl, dig y date (nunca salen a la red)
├── entrypoint.sh        # Entrypoint Docker (loop cada CHECK_INTERVAL)
├── Dockerfile           # Alpine + bash + curl + jq + dig
├── .env.example         # Plantilla de configuracion
├── state/               # State files (persisten entre ejecuciones)
│   ├── proxy_disabled.json      # Registros desactivados por el script
│   ├── proxy_disabled_ips.json  # IPs de Cloudflare guardadas por dominio: {"dominio": ["ip", ...]}
│   ├── proxy_disabled_clear.json  # Desde cuando esta libre cada dominio: {"dominio": epoch}
│   ├── proxy_disabled_outbox.json # Notificaciones de Telegram pendientes de reenviar (max 20)
│   ├── toggle-proxy.lock.d/       # Lock de ejecucion (con el PID dentro)
│   └── *.corrupt-<epoch>          # Ficheros corruptos en cuarentena

└── logs/                # Logs de ejecucion
    ├── toggle-proxy.log
    └── toggle-proxy.log.1, .2   # Rotados por tamano (LOG_MAX_BYTES)
```

## Tests

```bash
bash tests/run-all.sh          # unitarios, integracion y entrypoint con bash y /bin/bash
bash tests/test-integration.sh lock   # solo los escenarios cuyo nombre contiene "lock"
```

Los tests de integracion copian el script a un directorio temporal y sustituyen `curl`, `dig` y `date` por stubs (`tests/integration/bin`): nunca llaman a Cloudflare ni a Telegram. Cubren feed invalido, CIDR, numeros con ceros, fechas legacy en otra zona horaria, nombres en mayusculas, renombrados, PATCH incierto, state corrupto, paginacion, caidas del feed, restauraciones parciales, apex en gris, avisos de mitigacion parcial, bandeja de Telegram, lock y rotacion del log.

## Notificaciones Telegram

Configura `TELEGRAM_BOT_TOKEN` y `TELEGRAM_CHAT_ID` para recibir alertas:

**Cuando desactiva el proxy:**
> 🔴 **Proxy Cloudflare DESHABILITADO**
>
> LaLiga ha activado bloqueos. Se ha quitado el proxy en 2 registro(s) nuevo(s), 12 en total:
> - A example.com -> 1.2.3.4
> - A www.example.com -> 1.2.3.4
>
> Motivo:
> example.com: 5 coincidencias: DIGI 188.114.96.5 (same24), Movistar 188.114.97.5 (exact), Orange 188.114.96.7 (same24) +2 mas

Si la mitigacion es parcial, la alerta anade un bloque **Mitigacion parcial**: un CNAME con proxy que apunta fuera del dominio (si el destino tiene proxy, el trafico sigue pasando por Cloudflare) o un registro de solo lectura con proxy en ese nombre.

La alerta solo lista los registros deshabilitados en esa ejecucion: mientras el bloqueo sigue no se repite. El motivo se resume por dominio (total de coincidencias, las 3 primeras y "+N mas").

**Cuando lo reactiva:**
> 🟢 **Proxy Cloudflare REHABILITADO**
>
> El bloqueo ha terminado. Se ha restaurado el proxy en 12 registro(s).

Si solo se pudo restaurar una parte, la alerta lista lo restaurado y cuantos registros siguen en gris por dominio. Si un fichero de state esta corrupto llega una alerta ⚠️ con el fichero en cuarentena y los dominios a revisar.

Las listas largas se recortan (con "… (truncado)") para no pasar del limite de 4096 caracteres de Telegram. Si Telegram rechaza un mensaje, el log muestra `ERROR` con su `description`; los rechazos temporales (`429`, `5xx`, red) se guardan en `state/proxy_disabled_outbox.json` y se reenvian en la siguiente ejecucion.

## FAQ

### Solo afecta a webs en Espana?

El bloqueo lo hacen los ISPs espanoles (Movistar, Orange, Vodafone, DIGI, MasMovil). Usuarios de otros paises no se ven afectados. Al quitar el proxy CDN temporalmente, tus usuarios espanoles pueden acceder pero pierden la cache de Cloudflare durante el partido (~2-3h).

### Se pierde la cache de Cloudflare?

Si, durante el bloqueo el trafico va directo a tu servidor. Cuando el proxy se reactiva, la cache se reconstruye progresivamente.

### Que pasa si tengo registros que quiero mantener en gris?

El script solo desactiva registros que estan en naranja (proxied). Los que ya estan en gris nunca se tocan. Al rehabilitar, solo reactiva los que el mismo desactivo.

### Como se si mis IPs estan bloqueadas ahora?

Visita [hayahora.futbol](https://hayahora.futbol/) o ejecuta el script con `DRY_RUN=true`.

### Necesito dar de alta algo en hayahora.futbol?

No. La API es publica y gratuita. El script solo consulta `https://hayahora.futbol/estado/data.json`.

## Creditos

- [hayahora.futbol](https://hayahora.futbol/) - API de deteccion de bloqueos de LaLiga
- [Cloudflare API v4](https://developers.cloudflare.com/api/) - Gestion de DNS

## Licencia

MIT
