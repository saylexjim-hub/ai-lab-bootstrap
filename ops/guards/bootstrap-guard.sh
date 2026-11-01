#!/usr/bin/env bash
set -euo pipefail

# bootstrap-guard.sh — Audita cobertura del bootstrap
# Compara lo que está instalado en el sistema contra lo que
# ai-lab-bootstrap/modules/*.sh cubre.
# Uso: ~/ai-lab/ops/guards/bootstrap-guard.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/guard-lib.sh"

LAB_DIR="${LAB_DIR:-$HOME/ai-lab}"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-$LAB_DIR/repos/ai-lab-bootstrap}"

guard_init "bootstrap"

echo "[bootstrap-guard] $(date -Iseconds) Inicio de auditoría"

if [ ! -d "$BOOTSTRAP_DIR/modules" ]; then
  echo "[bootstrap-guard] WARN: $BOOTSTRAP_DIR no encontrado — solo verificando backup coverage."
fi

MODULES_CONTENT=""
if [ -d "$BOOTSTRAP_DIR/modules" ]; then
  MODULES_CONTENT=$(cat "$BOOTSTRAP_DIR/modules"/*.sh 2>/dev/null || echo "")
fi

BACKUP_SCRIPT="$LAB_DIR/ops/backup/lab-backup.sh"
if [ ! -f "$BACKUP_SCRIPT" ]; then
  BACKUP_SCRIPT="$LAB_DIR/scripts/lab-backup.sh"
fi
BACKUP_CONTENT=$(cat "$BACKUP_SCRIPT" 2>/dev/null || echo "")

# 1. Binarios en ~/.local/bin/ — ¿cubiertos por bootstrap o backup?
echo "[bootstrap-guard] Verificando binarios en ~/.local/bin/..."
if [ -d "$HOME/.local/bin" ]; then
  for bin in "$HOME/.local/bin"/*; do
    [ -f "$bin" ] || [ -L "$bin" ] || continue
    name=$(basename "$bin")
    [[ "$name" == *.old* ]] && continue

    in_bootstrap=false
    in_backup=false

    if [ -n "$MODULES_CONTENT" ]; then
      if echo "$MODULES_CONTENT" | grep -qi "$name" 2>/dev/null; then
        in_bootstrap=true
      fi
    fi

    if echo "$BACKUP_CONTENT" | grep -q '\.local/bin' 2>/dev/null; then
      in_backup=true
    fi

    if $in_bootstrap; then
      report_ok "binary" "$name"
    elif $in_backup; then
      report_ok "binary" "$name (backup-only)"
    else
      report_gap "binary" "$name" "no cubierto por bootstrap ni backup"
    fi
  done
fi

# 2. Servicios systemd user — ¿cubiertos?
# Cuando Dagu (system service) ejecuta este guard, DBUS no está disponible
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
echo "[bootstrap-guard] Verificando servicios systemd user..."
systemctl --user list-unit-files --state=enabled --type=service --no-pager --no-legend 2>/dev/null | while read -r unit _rest; do
  in_bootstrap=false
  in_backup=false

  if [ -n "$MODULES_CONTENT" ]; then
    svc_base=$(echo "$unit" | sed 's/\.service$//')
    if echo "$MODULES_CONTENT" | grep -qi "$svc_base" 2>/dev/null; then
      in_bootstrap=true
    fi
  fi

  if echo "$BACKUP_CONTENT" | grep -q 'systemd/user' 2>/dev/null; then
    in_backup=true
  fi

  if $in_bootstrap; then
    report_ok "systemd" "$unit"
  elif $in_backup; then
    report_ok "systemd" "$unit (backup-only)"
  else
    report_gap "systemd" "$unit" "no cubierto por bootstrap ni backup"
  fi
done

# 3. Containers Docker — ¿cubiertos por módulo 05 o stacks/?
echo "[bootstrap-guard] Verificando containers Docker..."
docker ps --format '{{.Names}}' 2>/dev/null | while read -r ctr; do
  in_bootstrap=false
  in_stacks=false

  if [ -n "$MODULES_CONTENT" ]; then
    if echo "$MODULES_CONTENT" | grep -qi "$ctr" 2>/dev/null; then
      in_bootstrap=true
    fi
  fi

  # Gobernanza por Compose: se le pregunta al CONTENEDOR, no a los archivos.
  #
  # Antes esto hacia grep del nombre del contenedor dentro de cada compose, y
  # fallaba en los dos sentidos:
  #
  #   - Falso GAP: Compose DERIVA el nombre del contenedor del proyecto mas el
  #     servicio. Con "name: paperclip" y servicio "db" el contenedor se llama
  #     "paperclip-db-1", cadena que no aparece en ninguna parte del archivo.
  #     Contenedores perfectamente gobernados se reportaban como GAP, el guard
  #     salia !=0 y el DAG lab-guards quedaba en failed todas las semanas.
  #
  #   - Falso OK: un contenedor creado con "docker run" se daba por cubierto si
  #     existia un compose que mencionara su nombre. Es el caso tipico de
  #     searxng y portainer desplegados a mano: el archivo esta, pero nadie
  #     puede recrear el contenedor desde el. El guard miraba el archivo, no el
  #     contenedor, que es justo lo contrario de lo que la pregunta requiere.
  #
  # Los labels que Compose escribe en el contenedor son la unica prueba de que
  # algo es reproducible desde codigo. Se reportan proyecto y working_dir para
  # que el hallazgo sea accionable.
  compose_project=$(docker inspect "$ctr" \
    --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)
  compose_workdir=$(docker inspect "$ctr" \
    --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null)
  if [ -n "$compose_project" ]; then
    in_stacks=true
  fi

  if $in_bootstrap; then
    report_ok "container" "$ctr"
  elif $in_stacks; then
    report_ok "container" "$ctr (compose: $compose_project @ ${compose_workdir:-?})"
  else
    report_gap "container" "$ctr" "creado con docker run — sin labels de Compose, no es reproducible desde codigo"
  fi
done

# 4. Repos APT de terceros — ¿cubiertos?
echo "[bootstrap-guard] Verificando repos APT de terceros..."
if [ -d /etc/apt/sources.list.d ]; then
  for src in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$src" ] || continue
    name=$(basename "$src")

    in_bootstrap=false
    in_backup=false

    if [ -n "$MODULES_CONTENT" ]; then
      src_base=$(echo "$name" | sed 's/\.\(list\|sources\)$//')
      if echo "$MODULES_CONTENT" | grep -qi "$src_base" 2>/dev/null; then
        in_bootstrap=true
      fi
    fi

    if echo "$BACKUP_CONTENT" | grep -q 'sources.list.d' 2>/dev/null; then
      in_backup=true
    fi

    if $in_bootstrap; then
      report_ok "apt-repo" "$name"
    elif $in_backup; then
      report_ok "apt-repo" "$name (backup-only)"
    else
      report_gap "apt-repo" "$name" "no cubierto por bootstrap ni backup"
    fi
  done
fi

# Emitir resultados
echo ""
echo "[bootstrap-guard] Resultados:"
JSON_FILE=$(emit_json)
emit_telegram
echo "[bootstrap-guard] Reporte JSON: $JSON_FILE"

guard_exit_code
