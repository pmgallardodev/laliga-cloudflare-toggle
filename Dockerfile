FROM alpine:3.20

RUN apk add --no-cache bash curl jq bind-tools

WORKDIR /app

COPY toggle-proxy.sh entrypoint.sh ./
COPY lib ./lib
RUN chmod +x toggle-proxy.sh entrypoint.sh

RUN mkdir -p /app/logs /app/state

# Intervalo en segundos entre ejecuciones (por defecto 5 min)
ENV CHECK_INTERVAL=300

# Unhealthy si el bucle lleva más de 3 intervalos sin dar una vuelta
HEALTHCHECK --interval=60s --timeout=5s --start-period=30s --retries=2 \
  CMD sh -c 'test $(( $(date +%s) - $(stat -c %Y /tmp/heartbeat) )) -lt $(( ${CHECK_INTERVAL:-300} * 3 ))'

# entrypoint.sh atiende TERM: reenvia la senal a la comprobacion en curso y
# sale con 0. Da margen al parar (una llamada a Cloudflare tarda hasta 30 s):
# docker stop -t 45 / stop_grace_period: 45s
STOPSIGNAL SIGTERM

ENTRYPOINT ["./entrypoint.sh"]
