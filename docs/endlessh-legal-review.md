# Resumen técnico — Endlessh (SSH tarpit) para revisión legal

**Para:** Lic. Gerardo Ronquilo
**Fecha:** 2026-05-30
**Asunto:** Naturaleza técnica y carácter defensivo del despliegue de `endlessh`

---

## 1. ¿Qué es endlessh?

Endlessh es un programa de código abierto que actúa como "tarpit" (trampa de
alquitrán) para conexiones SSH entrantes. Está publicado por Chris Wellons en
2019 bajo licencia MIT, y se distribuye en repositorios oficiales de
distribuciones Linux mayores (Debian, Ubuntu, Arch, etc.).

Repositorio oficial: https://github.com/skeeto/endlessh

## 2. ¿Qué hace técnicamente?

1. Escucha conexiones entrantes en el puerto TCP 22 (puerto estándar de SSH)
   **del propio servidor del operador**.
2. Cuando una IP intenta conectarse, el programa responde con un banner SSH
   "falso" enviado byte por byte con un retraso configurable (por defecto 10
   segundos entre bytes).
3. El protocolo SSH (RFC 4253) requiere que el banner termine en `\r\n` antes
   de iniciar la negociación. Endlessh nunca envía ese terminador, por lo que
   el cliente queda esperando indefinidamente.
4. La conexión se cierra solo si el cliente desiste, o si excede el límite
   configurado en el servidor.

## 3. ¿Qué NO hace?

- **No accede al sistema del cliente que conecta.**
- **No ejecuta código** en la máquina del que conecta.
- **No envía exploits, malware ni payloads.**
- **No recolecta información personal** del cliente más allá de la dirección
  IP que voluntariamente se identifica al iniciar la conexión TCP.
- **No "hackea de vuelta"** (hack-back).
- **No deniega servicio** a terceros: el operador del servidor mueve el
  servicio SSH legítimo a otro puerto para sus propios usos.

## 4. Modelo de amenaza y carácter defensivo

El puerto 22 recibe constantemente intentos automatizados de fuerza bruta de
botnets (un VPS típico ve miles de intentos diarios de IPs distintas). Las
opciones defensivas tradicionales son:

| Opción | Acción sobre el atacante |
|---|---|
| `fail2ban` | Bloquea su IP en el firewall |
| Mover puerto | Esconde el servicio |
| `endlessh` | Responde lento; no bloquea, no ataca |

Endlessh es **estrictamente menos intrusivo** que fail2ban: no bloquea
direcciones, no añade reglas de firewall, no marca al usuario. Simplemente
responde lentamente — comportamiento que el protocolo TCP/IP permite sin
restricción alguna.

## 5. Analogía jurídica

Endlessh es funcionalmente equivalente a:

- Tener una puerta con cerradura difícil: si alguien intenta forzarla, pierde
  tiempo. El propietario no agrede al intruso, solo no facilita el acceso.
- Un contestador automático que tarda en responder llamadas no deseadas: el
  receptor de la llamada no está obligado a responder con prontitud.

El servidor responde a una conexión que el cliente inició voluntariamente,
desde su propia infraestructura, sin interferir con sistemas ajenos.

## 6. Marco legal aplicable (referencia general)

Las legislaciones de delitos informáticos sancionan típicamente:

- **Acceso no autorizado a sistemas ajenos** — endlessh no realiza acceso.
- **Modificación o destrucción de datos ajenos** — endlessh no toca datos
  ajenos.
- **Interceptación ilícita de comunicaciones** — endlessh no intercepta nada;
  la comunicación es iniciada por el cliente hacia el servidor del operador.
- **Sabotaje o denegación de servicio** — endlessh no ataca a terceros; el
  cliente puede desconectarse en cualquier momento sin consecuencia.

Ninguna conducta sancionada se actualiza con la operación normal de endlessh.

## 7. Configuración desplegada

- Puerto expuesto: 22/TCP
- Retraso entre bytes: 10 000 ms (10 segundos)
- Líneas máximas del banner: 32
- Clientes simultáneos máximos: 1 000 000
- Registro de cierres en archivo local (IP, duración, bytes enviados) — usado
  exclusivamente para estadísticas internas del operador

## 8. Referencias

- Repositorio: https://github.com/skeeto/endlessh
- Paquete Debian: https://packages.debian.org/sid/endlessh
- Paquete Ubuntu: https://packages.ubuntu.com/jammy/endlessh
- Análisis técnico del autor: https://nullprogram.com/blog/2019/03/22/

---

*Documento preparado a solicitud del operador del servidor para revisión
legal. La descripción técnica refleja el comportamiento del software a la
fecha indicada según la versión empaquetada por linuxserver.io.*
