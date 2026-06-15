#!/usr/bin/env bash
#
# arch-updater.sh — actualizador de Arch paso a paso
#
# Flujo:
#   - Lista pendientes: oficiales (pacman) + AUR (yay/paru).
#   - Actualiza los oficiales en una pasada segura (-Syu) por defecto.
#   - Actualiza los de AUR uno a uno, reintentando 2 veces los que fallan.
#   - Cuando un paquete de AUR falla al compilar tras los reintentos:
#       1) anonimiza el log de error (usuario, /home, hostname),
#       2) lo sube a pastes.io (unlisted, caducidad ~30 días),
#       3) busca el MISMO paquete en los repos (quitando -git o por nombre)
#          y, si hay coincidencia exacta, lo instala automáticamente,
#       4) deja preparado un comentario para AUR con el enlace al log.
#   - Al final muestra en ROJO lo que ha quedado sin resolver y lo guarda
#     para reintentarlo (--reintentar).
#
# Uso:
#   ./arch-updater.sh                modo normal (oficiales -Syu, AUR uno a uno)
#   ./arch-updater.sh --listar       solo muestra lo pendiente, no toca nada
#   ./arch-updater.sh --una-a-una    oficiales también paquete a paquete (*)
#   ./arch-updater.sh --reintentar   reintenta lo que quedó pendiente antes
#
#   (*) "una a una" en oficiales es un partial upgrade, desaconsejado en Arch.
#       Se sincroniza la base de datos antes, pero úsalo a sabiendas.
#
# Cron (ejemplo, todos los días a las 04:00, como tu usuario normal):
#   0 4 * * *  /ruta/arch-updater.sh --reintentar >> ~/.cache/arch-updater.log 2>&1
#   Para que sea desatendido necesitas sudo sin contraseña SOLO para pacman:
#   en /etc/sudoers.d/arch-updater ->  tu_usuario ALL=(root) NOPASSWD: /usr/bin/pacman
#   (yay/paru NO se ejecutan con sudo; ellos llaman a sudo cuando lo necesitan.)

set -o pipefail

# ------------------------------------------------------------------ config ---
MAX_INTENTOS=2

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/arch-updater"
FALLIDOS_FILE="$STATE_DIR/fallidos.txt"
COMENTARIOS_FILE="$STATE_DIR/comentarios-aur.txt"
LOG_DIR="$STATE_DIR/logs"

# --- pastes.io ---------------------------------------------------------------
# NOTA: la doc de pastes.io es un Postman en JS y no expone el nombre exacto
# del campo de expiración. Si la caducidad no se aplica, ajusta estas 4 líneas
# según https://docs.pastes.io (el resto del script no cambia).
PASTE_API="https://pastes.io/api/paste"
PASTE_EXPIRE_PARAM="expire";      PASTE_EXPIRE_VALUE="1M"   # ~30 días
PASTE_VISIBILITY_PARAM="visibility"; PASTE_VISIBILITY_VALUE="1"  # 1 = unlisted

# --- Telegram (OPCIONAL, desactivado) ----------------------------------------
# Placeholder para cuando elijas la opción de bot. Si dejas el token vacío,
# no hace nada. Opción "A" (solo aviso): rellena estas dos variables.
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# --------------------------------------------------------------- argumentos ---
MODO_UNA_A_UNA=0
REINTENTAR=0
SOLO_LISTAR=0
for arg in "$@"; do
  case "$arg" in
    --una-a-una) MODO_UNA_A_UNA=1 ;;
    --reintentar) REINTENTAR=1 ;;
    --listar) SOLO_LISTAR=1 ;;
    *) echo "Argumento desconocido: $arg" >&2; exit 2 ;;
  esac
done

# ------------------------------------------------------------------ colores ---
if [ -t 1 ]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi
info() { printf '%s\n' "${C_CYAN}$*${C_RESET}"; }
ok()   { printf '%s\n' "${C_GREEN}$*${C_RESET}"; }
warn() { printf '%s\n' "${C_YELLOW}$*${C_RESET}"; }
err()  { printf '%s\n' "${C_RED}$*${C_RESET}"; }

# ------------------------------------------------------------------- estado ---
mkdir -p "$LOG_DIR"
: > "$COMENTARIOS_FILE"   # se regenera en cada ejecución

# arrays de resultado
declare -a ACTUALIZADOS=()
declare -a SUSTITUIDOS=()
declare -a FALLIDOS=()

# ----------------------------------------------------------------- helpers ----
detectar_helper() {
  if command -v paru >/dev/null 2>&1; then echo "paru"
  elif command -v yay >/dev/null 2>&1; then echo "yay"
  else echo ""; fi
}
HELPER="$(detectar_helper)"

get_oficiales() {
  # checkupdates (pacman-contrib) no toca la base de datos del sistema -> seguro
  if command -v checkupdates >/dev/null 2>&1; then
    checkupdates 2>/dev/null | awk '{print $1}'
  else
    pacman -Qu 2>/dev/null | awk '{print $1}'
  fi
}

get_aur() {
  [ -z "$HELPER" ] && return 0
  "$HELPER" -Qua 2>/dev/null | awk '{print $1}'
}

# anonimiza un log: usuario -> user, /home/usuario -> /home/user, hostname -> host
anonimizar() {
  local in="$1" out="$2" u h
  u="$(whoami)"; h="$(hostname 2>/dev/null)"
  sed -E \
      -e "s#/home/${u}#/home/user#g" \
      -e "s#([^A-Za-z0-9_]|^)${u}([^A-Za-z0-9_]|\$)#\1user\2#g" \
      ${h:+-e "s#([^A-Za-z0-9_.-]|^)${h}([^A-Za-z0-9_.-]|\$)#\1host\2#g"} \
      "$in" > "$out" 2>/dev/null || cp "$in" "$out"
}

# sube un fichero a pastes.io y devuelve (por stdout) la URL, o cadena vacía
subir_paste() {
  local file="$1" title="$2" resp url
  command -v curl >/dev/null 2>&1 || { warn "    curl no disponible, no subo log"; return 1; }
  resp="$(curl -fsS -X POST "$PASTE_API" \
            --data-urlencode "content@${file}" \
            --data-urlencode "title=build-error ${title}" \
            --data-urlencode "${PASTE_EXPIRE_PARAM}=${PASTE_EXPIRE_VALUE}" \
            --data-urlencode "${PASTE_VISIBILITY_PARAM}=${PASTE_VISIBILITY_VALUE}" 2>/dev/null)"
  # la respuesta suele traer la URL del paste (JSON o texto); la extraemos
  url="$(printf '%s' "$resp" | grep -oE 'https?://pastes\.io/[A-Za-z0-9._/-]+' | head -n1)"
  printf '%s' "$url"
}

# añade un comentario listo para pegar en AUR
preparar_comentario_aur() {
  local pkg="$1" url="$2"
  {
    echo "## ${pkg}  ->  https://aur.archlinux.org/packages/${pkg}"
    echo "Build fails after the latest update on Arch ($(date '+%Y-%m-%d'))."
    [ -n "$url" ] && echo "Compilation log: ${url}"
    echo
  } >> "$COMENTARIOS_FILE"
}

# busca el mismo paquete en los repos oficiales (coincidencia EXACTA de nombre)
alternativa_en_repos() {
  local pkg="$1" base cand
  base="${pkg%-git}"
  for cand in "$pkg" "$base"; do
    if pacman -Si "$cand" >/dev/null 2>&1; then
      echo "$cand"; return 0
    fi
  done
  return 1
}

# --------------------------------------------------------- acciones update ----
actualizar_oficiales_todos() {
  info "» Actualizando paquetes oficiales (pacman -Syu)..."
  if sudo pacman -Syu --noconfirm; then
    ok "  ✓ oficiales actualizados"; return 0
  fi
  err "  ✗ falló la actualización de oficiales"; return 1
}

actualizar_oficial_uno() {
  local pkg="$1" intento
  for intento in $(seq 1 "$MAX_INTENTOS"); do
    info "» $pkg ${C_DIM}(oficial, intento $intento/$MAX_INTENTOS)${C_RESET}"
    if sudo pacman -S --needed --noconfirm "$pkg"; then
      ok "  ✓ $pkg"; ACTUALIZADOS+=("$pkg"); return 0
    fi
    warn "  ⚠ fallo intento $intento"
  done
  FALLIDOS+=("$pkg")
  return 1
}

# gestiona el fallo de compilación de un paquete de AUR (protocolo de error)
protocolo_error_aur() {
  local pkg="$1" rawlog="$2" anonlog url alt
  warn "  ✗ $pkg falló tras $MAX_INTENTOS intentos — aplicando protocolo de error"

  anonlog="$(mktemp)"
  anonimizar "$rawlog" "$anonlog"
  url="$(subir_paste "$anonlog" "$pkg")"
  rm -f "$anonlog"
  if [ -n "$url" ]; then info "    log subido: $url"; else warn "    no se pudo subir el log"; fi

  preparar_comentario_aur "$pkg" "$url"

  if alt="$(alternativa_en_repos "$pkg")"; then
    info "    alternativa en repos encontrada: $alt — instalando..."
    if sudo pacman -S --needed --noconfirm "$alt"; then
      ok "    ✓ sustituido por $alt (revísalo en el resumen)"
      SUSTITUIDOS+=("$pkg -> $alt")
      return 0
    fi
    warn "    no se pudo instalar la alternativa $alt"
  else
    info "    sin alternativa en repos"
  fi
  return 1
}

actualizar_aur_uno() {
  local pkg="$1" intento logfile
  logfile="$LOG_DIR/${pkg//\//_}.log"
  for intento in $(seq 1 "$MAX_INTENTOS"); do
    info "» $pkg ${C_DIM}(AUR, intento $intento/$MAX_INTENTOS)${C_RESET}"
    if "$HELPER" -S --needed --noconfirm "$pkg" 2>&1 | tee "$logfile"; then
      ok "  ✓ $pkg"; ACTUALIZADOS+=("$pkg"); return 0
    fi
    warn "  ⚠ fallo intento $intento"
  done
  if protocolo_error_aur "$pkg" "$logfile"; then
    return 0
  fi
  FALLIDOS+=("$pkg")
  return 1
}

# --------------------------------------------------------------- telegram -----
notificar_telegram() {
  [ -z "$TELEGRAM_BOT_TOKEN" ] && return 0
  [ -z "$TELEGRAM_CHAT_ID" ] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsS -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------- main ------
main() {
  printf '%s\n' "${C_BOLD}== arch-updater ==${C_RESET}"
  if [ -n "$HELPER" ]; then
    printf '%s\n' "${C_DIM}Helper AUR: $HELPER${C_RESET}"
  else
    printf '%s\n' "${C_DIM}Sin helper AUR (solo repos oficiales).${C_RESET}"
  fi

  # 1) listado de pendientes
  mapfile -t OFICIALES < <(get_oficiales)
  mapfile -t AUR < <(get_aur)

  declare -a REINTENTOS=()
  if [ "$REINTENTAR" -eq 1 ] && [ -f "$FALLIDOS_FILE" ]; then
    mapfile -t REINTENTOS < "$FALLIDOS_FILE"
    [ "${#REINTENTOS[@]}" -gt 0 ] && \
      printf '%s\n' "${C_DIM}Reintentando ${#REINTENTOS[@]} pendiente(s) de antes.${C_RESET}"
  fi

  echo
  printf '%s\n' "${C_BOLD}Pendientes:${C_RESET}"
  echo "  Oficiales (${#OFICIALES[@]}): ${OFICIALES[*]:-—}"
  echo "  AUR (${#AUR[@]}): ${AUR[*]:-—}"

  if [ "$SOLO_LISTAR" -eq 1 ]; then
    printf '\n%s\n' "${C_DIM}(modo --listar: no se actualiza nada)${C_RESET}"
    return 0
  fi

  if [ "${#OFICIALES[@]}" -eq 0 ] && [ "${#AUR[@]}" -eq 0 ] && [ "${#REINTENTOS[@]}" -eq 0 ]; then
    printf '\n%s\n' "${C_GREEN}El sistema ya está al día. Nada que hacer.${C_RESET}"
    return 0
  fi

  echo
  # 2) oficiales primero (deja el sistema al día antes de tocar AUR)
  if [ "${#OFICIALES[@]}" -gt 0 ]; then
    if [ "$MODO_UNA_A_UNA" -eq 1 ]; then
      warn "AVISO: --una-a-una es un partial upgrade, desaconsejado en Arch."
      sudo pacman -Sy
      for pkg in "${OFICIALES[@]}"; do actualizar_oficial_uno "$pkg"; done
    else
      if actualizar_oficiales_todos; then
        ACTUALIZADOS+=("${OFICIALES[@]}")
      else
        FALLIDOS+=("${OFICIALES[@]}")
      fi
    fi
  fi

  # 3) AUR uno a uno
  for pkg in "${AUR[@]}"; do actualizar_aur_uno "$pkg"; done

  # 4) reintentos de ejecuciones previas
  for pkg in "${REINTENTOS[@]}"; do
    [ -z "$pkg" ] && continue
    if [ -n "$HELPER" ]; then actualizar_aur_uno "$pkg"; else actualizar_oficial_uno "$pkg"; fi
  done

  # 5) resumen ----------------------------------------------------------------
  echo
  printf '%s\n' "${C_BOLD}== Resumen ==${C_RESET}"
  ok "Actualizados: ${#ACTUALIZADOS[@]}"
  if [ "${#SUSTITUIDOS[@]}" -gt 0 ]; then
    warn "Sustituidos por alternativa en repos (revísalos):"
    for s in "${SUSTITUIDOS[@]}"; do warn "   - $s"; done
  fi

  # deduplicar fallidos y guardarlos
  local resumen_txt
  if [ "${#FALLIDOS[@]}" -gt 0 ]; then
    mapfile -t FALLIDOS < <(printf '%s\n' "${FALLIDOS[@]}" | awk 'NF' | sort -u)
    err "✗ Sin resolver (${#FALLIDOS[@]}):"
    for pkg in "${FALLIDOS[@]}"; do err "   - $pkg"; done
    printf '%s\n' "${FALLIDOS[@]}" > "$FALLIDOS_FILE"
    printf '%s\n' "${C_DIM}Guardados en $FALLIDOS_FILE — reintenta con: $0 --reintentar${C_RESET}"
    [ -s "$COMENTARIOS_FILE" ] && \
      printf '%s\n' "${C_DIM}Comentarios para AUR listos en: $COMENTARIOS_FILE${C_RESET}"
    resumen_txt="arch-updater: ${#ACTUALIZADOS[@]} actualizados, ${#SUSTITUIDOS[@]} sustituidos, ${#FALLIDOS[@]} sin resolver."
    notificar_telegram "$resumen_txt"
    return 1
  else
    : > "$FALLIDOS_FILE"
    ok "✓ Todo resuelto."
    [ -s "$COMENTARIOS_FILE" ] && \
      printf '%s\n' "${C_DIM}Hay comentarios para AUR en: $COMENTARIOS_FILE${C_RESET}"
    notificar_telegram "arch-updater: sistema al día (${#ACTUALIZADOS[@]} actualizados, ${#SUSTITUIDOS[@]} sustituidos)."
    return 0
  fi
}

main
