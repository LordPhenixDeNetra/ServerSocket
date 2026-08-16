#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Diagnostic robuste — Backend Transplantation Rénale (Hostinger / Dockploy)
# Usage :
#   bash diagnostic-nephro-backend.sh
# Output :  stdout + fichier de log horodaté dans /tmp/diagnostic-nephro-*.log
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
TS=$(date +%Y%m%d-%H%M%S)
LOG_FILE="/tmp/diagnostic-nephro-${TS}.log"
OK_SYM="✅"
WARN_SYM="⚠️"
ERR_SYM="❌"
INFO_SYM="ℹ️"
LINE="───────────────────────────────────────────────────────────────────────────────"

# Couleurs (désactivées si stdout pas un TTY)
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
section() {
  local title="$1"
  local out="${C_BOLD}${C_BLUE}${LINE}\n  ${title}\n${LINE}${C_RESET}"
  printf '\b\n'
  printf '%b\n' "$out"
}

log_cmd() {
  # Affiche + exécute une commande ; capture retour dans fichier & stdout ;
  # ne fait JAMAIS échouer le script global.
  local desc="$1"; shift
  printf '%b\n' "${INFO_SYM}  ${desc} :" | tee -a "$LOG_FILE"
  printf '$ %s\n' "$*" | tee -a "$LOG_FILE"
  "$@" 2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    printf '%b\n' "${WARN_SYM}  commande sortie code=$rc" | tee -a "$LOG_FILE"
  fi
  return 0
}

summary_entry() {
  # Stocke une entrée du résumé final
  SUMMARY_ENTRIES+=("$1")
}

# ─────────────────────────────────────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────────────────────────────────────
SUMMARY_ENTRIES=()

printf '%b\n' "${C_BOLD}Diagnostic Transplantation Rénale Backend${C_RESET}"
printf '%b\n' "${INFO_SYM}  Rapport enregistré dans : ${C_BOLD}${LOG_FILE}${C_RESET}"
echo "$LINE" | tee -a "$LOG_FILE"
date -R | tee -a "$LOG_FILE"
uname -a | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Vérification docker
if ! command -v docker >/dev/null 2>&1; then
  printf '%b\n' "${ERR_SYM}  'docker' introuvable dans PATH. Installer Docker / vérifier l'utilisateur (groupe docker ?)."
  exit 2
fi
if ! docker version >/dev/null 2>&1; then
  printf '%b\n' "${ERR_SYM}  Impossible d'interroger le démon Docker. Utilisateur dans le groupe 'docker' ? sudo usermod -aG docker \$USER"
  exit 3
fi

# ─────────────────────────────────────────────────────────────────────────────
# (1) Services Docker Swarm
# ─────────────────────────────────────────────────────────────────────────────
section "(1) Services Docker Swarm déployés"
log_cmd "Liste des services" \
  docker service ls --format 'table {{.Name}}\t{{.Replicas}}\t{{.Image}}\t{{.Ports}}'

# Auto-détection services cibles
NEPHRO_BE_SVC=$(docker service ls --format '{{.Name}}' \
  | grep -E 'nephro.*backend|transplantation.*backend' | head -1 || true)
PG_SVC=$(docker service ls --format '{{.Name}}' \
  | grep -E 'postgresqldatabase-postgresql|postgres' \
  | grep -v dokploy | grep -v pgadmin | head -1 || true)
HOPITALIA_BE_SVC=$(docker service ls --format '{{.Name}}' \
  | grep -E 'hopitalia.*backend' | head -1 || true)

printf '%b\n' "${INFO_SYM}  Auto-détection :
  - Backend nephro      : ${C_BOLD}${NEPHRO_BE_SVC:-<INTROUVABLE>}${C_RESET}
  - PostgreSQL          : ${C_BOLD}${PG_SVC:-<INTROUVABLE>}${C_RESET}
  - Référence (Hopitalia-BE) : ${C_BOLD}${HOPITALIA_BE_SVC:-<INTROUVABLE>}${C_RESET}"

if [ -z "$NEPHRO_BE_SVC" ]; then
  summary_entry "${ERR_SYM} Aucun service Swarm 'nephro-backend' / 'transplantation-backend' détecté → recréez-le dans Dockploy."
  printf '%b\n' "\n${ERR_SYM}  ABANDON : service backend cible introuvable."
  printf '%s\n' "$LINE"
  printf '%b\n' "${C_BOLD}Résumé rapide :${C_RESET}"
  for e in "${SUMMARY_ENTRIES[@]}"; do printf ' - %s\n' "$e"; done
  exit 4
fi

# ─────────────────────────────────────────────────────────────────────────────
# (2) Tâches Swarm du backend (erreurs scheduling)
# ─────────────────────────────────────────────────────────────────────────────
section "(2) Tâches Swarm — erreurs de scheduling / crashs"
log_cmd "docker service ps (sans trunc)" \
  docker service ps --no-trunc "$NEPHRO_BE_SVC"

# Heuristique sur Replicas
REPLICAS=$(docker service ls --filter "name=$NEPHRO_BE_SVC" --format '{{.Replicas}}')
if [ "$REPLICAS" = "0/1" ]; then
  summary_entry "${ERR_SYM} Replicas=${REPLICAS} : Swarm n'a JAMAIS réussi à lancer un conteneur stable → voir service ps + resources/network/limits."
else
  summary_entry "${OK_SYM} Replicas=${REPLICAS} — scheduling réussi."
fi

# ─────────────────────────────────────────────────────────────────────────────
# (3) Configuration complète du backend (resources / env / mounts / healthcheck)
# ─────────────────────────────────────────────────────────────────────────────
section "(3) Configuration service ${NEPHRO_BE_SVC}"
log_cmd "Inspect service (ressources, réseau, mounts, health)" \
  docker service inspect "$NEPHRO_BE_SVC" --format '
Image:           {{.Spec.TaskTemplate.ContainerSpec.Image}}
Command:         {{.Spec.TaskTemplate.ContainerSpec.Command}}
Args:            {{.Spec.TaskTemplate.ContainerSpec.Args}}
Hostname:        {{.Spec.TaskTemplate.ContainerSpec.Hostname}}
DNS:             {{.Spec.TaskTemplate.ContainerSpec.DNSConfig}}
RestartPolicy:   cond={{.Spec.TaskTemplate.RestartPolicy.Condition}} max={{.Spec.TaskTemplate.RestartPolicy.MaxAttempts}} delay={{.Spec.TaskTemplate.RestartPolicy.Delay}}
UpdateConfig:    parallel={{.Spec.UpdateConfig.Parallelism}} failure-action={{.Spec.UpdateConfig.FailureAction}} monitor={{.Spec.UpdateConfig.Monitor}}
RollbackConfig:  parallel={{.Spec.RollbackConfig.Parallelism}} failure-action={{.Spec.RollbackConfig.FailureAction}}
Resources:
  limits        mem={{.Spec.TaskTemplate.Resources.Limits.MemoryBytes}}B nano-cpus={{.Spec.TaskTemplate.Resources.Limits.NanoCPUs}}
  reservations  mem={{.Spec.TaskTemplate.Resources.Reservations.MemoryBytes}}B nano-cpus={{.Spec.TaskTemplate.Resources.Reservations.NanoCPUs}}
Networks:        {{range .Spec.TaskTemplate.Networks}}{{.Target}} {{end}}
Mounts:
{{- range .Spec.TaskTemplate.ContainerSpec.Mounts}}
  type={{.Type}} src={{.Source}} tgt={{.Target}} readonly={{.ReadOnly}}
{{- end}}
Healthcheck:
  Test:        {{.Spec.TaskTemplate.ContainerSpec.Healthcheck.Test}}
  Interval:    {{.Spec.TaskTemplate.ContainerSpec.Healthcheck.Interval}}
  Timeout:     {{.Spec.TaskTemplate.ContainerSpec.Healthcheck.Timeout}}
  Retries:     {{.Spec.TaskTemplate.ContainerSpec.Healthcheck.Retries}}
  StartPeriod: {{.Spec.TaskTemplate.ContainerSpec.Healthcheck.StartPeriod}}
Ports published:
{{- range .Endpoint.Ports}}
  host=0.0.0.0:{{.PublishedPort}}  target={{.TargetPort}}/{{.Protocol}}  mode={{.PublishMode}}
{{- else}}
  (aucun port publié — utilisation Traefik attendue)
{{- end}}
'

section "Variables d'environnement effectives"
ENV_VARS=$(docker service inspect "$NEPHRO_BE_SVC" --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}')
printf '%s\n' "$ENV_VARS" | tee -a "$LOG_FILE"

# ── Heuristiques ENV ─────────────────────────────────────────────────────────
HAS_JWT_SECRET=0; HAS_DB_URL=0; HAS_DB_USR=0; HAS_DB_PWD=0; HAS_DDL_AUTO=0
while IFS= read -r line; do
  case "$line" in
    APP_JWT_SECRET=*)  val="${line#APP_JWT_SECRET=}"; [ -n "$val" ] && HAS_JWT_SECRET=1 ;;
    SPRING_DATASOURCE_URL=*) val="${line#SPRING_DATASOURCE_URL=}"; [ -n "$val" ] && HAS_DB_URL=1 ;;
    SPRING_DATASOURCE_USERNAME=*) val="${line#SPRING_DATASOURCE_USERNAME=}"; [ -n "$val" ] && HAS_DB_USR=1 ;;
    SPRING_DATASOURCE_PASSWORD=*) val="${line#SPRING_DATASOURCE_PASSWORD=}"; [ -n "$val" ] && HAS_DB_PWD=1 ;;
    SPRING_JPA_HIBERNATE_DDL_AUTO=*) HAS_DDL_AUTO=1 ;;
  esac
done <<< "$ENV_VARS"

[ "$HAS_JWT_SECRET" -eq 0 ] && summary_entry "${ERR_SYM} Variable APP_JWT_SECRET absente OU vide → Spring crash à l'initialisation JwtService."
[ "$HAS_DB_URL"     -eq 0 ] && summary_entry "${ERR_SYM} Variable SPRING_DATASOURCE_URL absente."
[ "$HAS_DB_USR"     -eq 0 ] && summary_entry "${ERR_SYM} Variable SPRING_DATASOURCE_USERNAME absente."
[ "$HAS_DB_PWD"     -eq 0 ] && summary_entry "${ERR_SYM} Variable SPRING_DATASOURCE_PASSWORD absente OU vide."
if [ "$HAS_JWT_SECRET" -eq 1 ] && [ "$HAS_DB_URL" -eq 1 ] && [ "$HAS_DB_USR" -eq 1 ] && [ "$HAS_DB_PWD" -eq 1 ]; then
  summary_entry "${OK_SYM} Quatre variables critiques (JWT+DB×3) présentes."
fi
[ "$HAS_DDL_AUTO"   -eq 0 ] && summary_entry "${WARN_SYM} SPRING_JPA_HIBERNATE_DDL_AUTO absent → profile deploy utilise 'validate' par défaut (sur base vide → SchemaManagementException)."

# ─────────────────────────────────────────────────────────────────────────────
# (4) Réseau : backend ↔ Postgres ↔ référence
# ─────────────────────────────────────────────────────────────────────────────
section "(4) Réseaux Swarm (backend ↔ Postgres ↔ référence)"

NET_NEPHRO=$(docker service inspect "$NEPHRO_BE_SVC" --format '{{range .Spec.TaskTemplate.Networks}}{{.Target}} {{end}}' 2>/dev/null || true)
NET_PG=""
if [ -n "$PG_SVC" ]; then
  NET_PG=$(docker service inspect "$PG_SVC" --format '{{range .Spec.TaskTemplate.Networks}}{{.Target}} {{end}}' 2>/dev/null || true)
fi
NET_HOP=""
if [ -n "$HOPITALIA_BE_SVC" ]; then
  NET_HOP=$(docker service inspect "$HOPITALIA_BE_SVC" --format '{{range .Spec.TaskTemplate.Networks}}{{.Target}} {{end}}' 2>/dev/null || true)
fi

printf 'Backend nephro  : %s\n' "${NET_NEPHRO:-<aucun>}"
printf 'PostgreSQL      : %s\n' "${NET_PG:-<aucun>}"
printf 'Référence (Hop) : %s\n' "${NET_HOP:-<aucun>}"

# Intersection : backend partage-t-il au moins un réseau avec Postgres ?
SHARED=""
for n1 in $NET_NEPHRO; do
  for n2 in $NET_PG; do
    [ "$n1" = "$n2" ] && SHARED="${SHARED}${n1} "
  done
done
if [ -z "$SHARED" ]; then
  summary_entry "${ERR_SYM} Backend et PostgreSQL N'ONT AUCUN réseau commun → JDBC échouera (UnknownHostException)."
else
  summary_entry "${OK_SYM} Réseau(x) partagé(s) backend↔Postgres : ${SHARED}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# (5) Conteneurs en vie sur le nœud (ancêtre transplantation-backend)
# ─────────────────────────────────────────────────────────────────────────────
section "(5) Conteneurs (Running / Exited) liés à l'image"
log_cmd "docker ps -a filtration image" \
  docker ps -a --filter "ancestor=sadhub/transplantation-backend:latest" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}\t{{.Ports}}'

# ─────────────────────────────────────────────────────────────────────────────
# (6) Docker Hub : pull possible ? (rate limit ?)
# ─────────────────────────────────────────────────────────────────────────────
section "(6) Test pull image sadhub/transplantation-backend:latest (Docker Hub rate limit ?)"
PULL_OUT=$(docker pull sadhub/transplantation-backend:latest 2>&1 | tail -15)
printf '%s\n' "$PULL_OUT"
if grep -qiE 'rate limit|toomanyrequests|429' <<<"$PULL_OUT"; then
  summary_entry "${ERR_SYM} Docker Hub rate-limité → pull impossible ; 'docker login -u <user>' requis sur ce serveur."
elif grep -qiE 'manifest unknown|not found' <<<"$PULL_OUT"; then
  summary_entry "${ERR_SYM} Image :latest absente sur Docker Hub → faites un 'docker push sadhub/transplantation-backend:latest' depuis votre PC."
else
  summary_entry "${OK_SYM} Pull Docker Hub OK."
fi

# ─────────────────────────────────────────────────────────────────────────────
# (7) Logs Spring Boot (service)
# ─────────────────────────────────────────────────────────────────────────────
section "(7) Logs Spring Boot du service ${NEPHRO_BE_SVC} (300 dernières lignes)"
LOGS_OUT=$(docker service logs --tail 300 "$NEPHRO_BE_SVC" 2>&1 | tail -150)
if [ -z "${LOGS_OUT//[$'\t\r\n ']}" ]; then
  printf '%b\n' "${WARN_SYM}  <aucun log — Spring n'a probablement JAMAIS booté (scheduling rejeté / mauvais healthcheck)."
  summary_entry "${WARN_SYM} Logs Spring VIDES → scheduling jamais abouti (contraintes placement / resources / mauvaise image)."
else
  printf '%s\n' "$LOGS_OUT" | tee -a "$LOG_FILE"
  if grep -qi 'InvalidConfigDataPropertyException' <<<"$LOGS_OUT"; then
    summary_entry "${ERR_SYM} spring.profiles.active défini DANS application-deploy.properties → corrigé mais image Docker HUB pas à jour : REBUILD + REPUSH."
  fi
  if grep -qi "Could not resolve placeholder.*app.jwt.secret" <<<"$LOGS_OUT"; then
    summary_entry "${ERR_SYM} APP_JWT_SECRET mal ou pas injectée malgré présence en ENV (typo ?)."
  fi
  if grep -qiE 'PSQLException.*Connection refused|UnknownHostException' <<<"$LOGS_OUT"; then
    summary_entry "${ERR_SYM} JDBC : Postgres injoignable → SPRING_DATASOURCE_URL host faux OU absence réseau partagé."
  fi
  if grep -qiE 'SchemaManagementException|missing table|schema.validator' <<<"$LOGS_OUT"; then
    summary_entry "${ERR_SYM} Hibernate ddl-auto=validate + tables absentes → ajoutez SPRING_JPA_HIBERNATE_DDL_AUTO=update pour ce 1er run."
  fi
  if grep -qi 'Started.*JVM running for' <<<"$LOGS_OUT"; then
    summary_entry "${OK_SYM} Spring Boot a démarré (message 'JVM running for' présent) → l'échec est hors app (Traefik route / healthcheck / port)."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# (8) Resources système (RAM / disque)
# ─────────────────────────────────────────────────────────────────────────────
section "(8) Santé nœud : RAM + disque"
log_cmd "Mémoire libre + swap" free -h
log_cmd "Espace disque (points critiques)" df -h /tmp /var/lib/docker / 2>/dev/null || df -h

FREE_RAM=$(awk '/^Mem:/{print $7}' /proc/meminfo 2>/dev/null || echo "0")
FREE_RAM_MB=$((FREE_RAM / 1024))
if [ "$FREE_RAM_MB" -lt 400 ]; then
  summary_entry "${WARN_SYM} Moins de 400MB RAM disponible → conteneur Java tué par OOMKiller possible."
fi

# ─────────────────────────────────────────────────────────────────────────────
# (9) Test direct curl si un conteneur tourne (évite le proxy Traefik)
# ─────────────────────────────────────────────────────────────────────────────
section "(9) Curl direct sur le conteneur (via IP Swarm conteneur / bypass Traefik)"
RUNNING=$(docker ps -q --filter "ancestor=sadhub/transplantation-backend:latest" --filter "status=running" | head -1)
if [ -n "$RUNNING" ]; then
  CIP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$RUNNING" 2>/dev/null | awk '{print $1}')
  if [ -n "$CIP" ]; then
    log_cmd "GET http://${CIP}:8080/actuator/health (Spring direct)" \
      curl -sv --max-time 10 "http://${CIP}:8080/actuator/health" 2>&1 | tail -30
  else
    printf '%b\n' "${WARN_SYM}  Conteneur running mais IP introuvable (network host ?)."
  fi
else
  printf '%b\n' "${WARN_SYM}  Aucun conteneur 'running' — curl direct impossible."
fi

# ─────────────────────────────────────────────────────────────────────────────
# (10) Traefik (référence) : route / labels nephro-backend
# ─────────────────────────────────────────────────────────────────────────────
section "(10) Configuration Traefik (labels du service nephro-backend)"
LABELS=$(docker service inspect "$NEPHRO_BE_SVC" --format '{{range $k,$v := .Spec.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' 2>/dev/null)
if [ -z "$LABELS" ]; then
  summary_entry "${WARN_SYM} Aucun label Traefik sur le service → Dockploy doit les injecter via son UI (domaine + port cible)."
else
  printf '%s\n' "$LABELS" | tee -a "$LOG_FILE"
  if ! grep -qiE 'traefik.*enable|traefik\.http\.services|traefik\.http\.routers' <<<"$LABELS"; then
    summary_entry "${WARN_SYM} Labels Traefik détectés mais absence de route/service → vérifiez le domaine rattaché dans Dockploy."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# RÉSUMÉ FINAL
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "$LINE"
printf '%b\n' "${C_BOLD}📋 Résumé rapide des problèmes détectés :${C_RESET}"
echo "$LINE"
if [ "${#SUMMARY_ENTRIES[@]}" -eq 0 ]; then
  printf ' %s Aucun problème évident détecté — revoyez la configuration du domaine et les logs Traefik.\n' "${OK_SYM}"
else
  for entry in "${SUMMARY_ENTRIES[@]}"; do
    printf '  * %s\n' "$entry"
  done
fi
echo ""
printf '%b\n' "${INFO_SYM}  Rapport complet enregistré sous : ${C_BOLD}${LOG_FILE}${C_RESET}"
printf '%b\n' "  Collez ce fichier ou son contenu dans votre ticket de support / conversation Trae."
echo "$LINE"
