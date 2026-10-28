#!/usr/bin/env bash
set -euo pipefail
umask 077

if (( EUID != 0 )); then
  echo 'ERROR: Ejecuta este instalador como root.' >&2
  exit 1
fi

STAGE=$(mktemp -d /tmp/rdz-rufu-dias.XXXXXX)
trap 'rm -rf -- "$STAGE"' EXIT

cat > "$STAGE/demos" <<'DEMOS'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

if (( EUID != 0 )); then echo 'Ejecuta como root.' >&2; exit 1; fi

echo '========================================'
echo ' GENERADOR DEMO - ADMRufu 2.0 (DIAS)'
echo '========================================'
read -r -p 'Prefijo (ej: DEMO): ' prefijo
read -r -p 'Cantidad de usuarios (1-200): ' cantidad
read -r -p 'Duracion en dias (1-365): ' dias
read -r -p 'Limite de conexiones (1-10): ' limite
read -rs -p 'Contraseña temporal: ' clave
echo

if [[ ! "$prefijo" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] ||
   (( ${#prefijo} > 20 )) ||
   [[ ! "$cantidad" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$dias" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$limite" =~ ^[1-9][0-9]*$ ]] ||
   (( cantidad > 200 || dias > 365 || limite > 10 )) ||
   [[ ! "$clave" =~ ^[A-Za-z0-9._@-]{4,32}$ ]]; then
  echo 'Datos invalidos. La contraseña debe tener 4-32 caracteres: letras, numeros, . _ @ -'
  exit 1
fi

# Rufu utiliza limite,contraseña en el comentario de la cuenta.
# Esto es visible mediante getent passwd: SOLO contraseñas exclusivas para demos.
vencimiento=$(date -d "+$dias days" +%F)
archivo=$(mktemp /root/demos-XXXXXX.txt)
creados=0

for (( i=1; i<=cantidad; i++ )); do
  usuario="${prefijo}${i}"
  if id "$usuario" >/dev/null 2>&1; then
    echo "Ya existe: $usuario (omitido)"
    continue
  fi
  if useradd -M -s /bin/false -c "$limite,$clave" -e "$vencimiento" "$usuario"; then
    if printf '%s:%s\n' "$usuario" "$clave" | chpasswd; then
      printf 'Usuario: %s | Contraseña: %s\n' "$usuario" "$clave" >> "$archivo"
      echo "Creado: $usuario"
      creados=$((creados + 1))
    else
      userdel "$usuario" || true
      echo "ERROR configurando la contraseña de $usuario" >&2
    fi
  else
    echo "ERROR creando $usuario" >&2
  fi
done

echo '========================================'
printf 'Cuentas creadas: %d\n' "$creados"
printf 'Vencimiento por fecha: %s\n' "$vencimiento"
printf 'Lista privada: %s\n' "$archivo"
echo '========================================'
DEMOS

cat > "$STAGE/usuarios" <<'USUARIOS'
#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

if (( EUID != 0 )); then echo 'Ejecuta como root.' >&2; exit 1; fi

DB=/var/lib/rdz-demos/pendientes.tsv
LOCK=/var/lib/rdz-demos/.candado

# Solo cuentas SSH con el mismo formato detectado en ADMRufu 2.0.
es_rufu() {
  local u="$1" uid_esperado="${2:-}" linea nombre x uid gid gecos home shell
  linea=$(getent passwd "$u") || return 1
  IFS=: read -r nombre x uid gid gecos home shell <<< "$linea"
  [[ "$nombre" == "$u" && "$uid" =~ ^[0-9]+$ ]] || return 1
  (( uid >= 1000 )) || return 1
  [[ "$shell" == /bin/false && "$gecos" =~ ^[0-9]+, ]] || return 1
  [[ -z "$uid_esperado" || "$uid" == "$uid_esperado" ]]
}

# Retira una demo del temporizador ANTERIOR si se renueva o elimina.
# No modifica las otras demos pendientes.
quitar_pendiente() {
  local u="$1" uid="$2" tmp
  [[ -f "$DB" ]] || return 0
  tmp=$(mktemp /var/lib/rdz-demos/.usuarios.XXXXXX) || return 1
  if ! awk -F '\t' -v u="$u" -v uid="$uid" \
    '!($1==u && $2==uid)' "$DB" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$DB"
}

mostrar() {
  local u="$1" linea nombre x uid gid gecos home shell vence estado
  linea=$(getent passwd "$u") || return 1
  IFS=: read -r nombre x uid gid gecos home shell <<< "$linea"
  vence=$(chage -l "$u" 2>/dev/null | awk -F: '/^Account expires[[:space:]]*:/ {sub(/^[[:space:]]+/, "", $2); print $2}')
  estado=$(passwd -S "$u" 2>/dev/null | awk '{print $2}')
  echo '-------------------------------------------'
  printf 'Usuario: %s\n' "$u"
  printf 'Conexiones (en Rufu): %s\n' "${gecos%%,*}"
  printf 'Vencimiento: %s\n' "${vence:-No disponible}"
  # Dias de calendario restantes hasta la fecha de expiracion de chage.
  # UTC solo se usa para el calculo de fechas: evita diferencias por horario de verano.
  local dias_texto='No disponible' fecha_vencimiento hoy_seg vence_seg restantes
  if [[ "$vence" == never || "$vence" == Never ]]; then
    dias_texto='Sin vencimiento'
  elif [[ -n "$vence" ]]; then
    fecha_vencimiento=$(date -d "$vence" +%F 2>/dev/null || true)
    if [[ -n "$fecha_vencimiento" ]]; then
      hoy_seg=$(date -u -d "$(date +%F)" +%s)
      vence_seg=$(date -u -d "$fecha_vencimiento" +%s)
      restantes=$(( (vence_seg - hoy_seg) / 86400 ))
      if (( restantes > 0 )); then
        if (( restantes == 1 )); then
          dias_texto='1 dia'
        else
          dias_texto="$restantes dias"
        fi
      elif (( restantes == 0 )); then
        dias_texto='0 dias (vence hoy)'
      else
        dias_texto="0 dias (vencio hace $((-restantes)) dias)"
      fi
    fi
  fi
  printf 'Dias restantes: %s\n' "$dias_texto"
  printf 'Estado de contraseña: %s\n' "${estado:-Desconocido}"
  if [[ -f "$DB" ]] && awk -F '\t' -v u="$u" -v uid="$uid" \
     '$1==u && $2==uid {found=1} END{exit !found}' "$DB"; then
    echo 'Aviso: esta cuenta aun tiene un vencimiento anterior por horas.'
    echo 'Renovarla por dias quitara ese vencimiento anterior.'
  fi
  echo '-------------------------------------------'
}

renovar() {
  local u="$1" uid="$2" dias fecha confirm estado
  read -r -p 'Cantidad de dias desde hoy (1-365): ' dias
  if [[ ! "$dias" =~ ^[1-9][0-9]*$ ]] || (( dias > 365 )); then
    echo 'Dias invalidos.'
    return 0
  fi
  fecha=$(date -d "+$dias days" +%F)
  printf 'Nuevo vencimiento de %s: %s (fecha calendario)\n' "$u" "$fecha"
  read -r -p "Para renovar $u escribe SI: " confirm
  [[ "$confirm" == SI ]] || { echo 'Cancelado.'; return 0; }

  mkdir -p /var/lib/rdz-demos
  chmod 700 /var/lib/rdz-demos
  (
    flock -x 9
    if ! es_rufu "$u" "$uid"; then
      echo 'La cuenta cambio o ya no existe. Cancelado.'
      exit 1
    fi
    if ! chage -E "$fecha" "$u"; then
      echo 'No se pudo actualizar el vencimiento.'
      exit 1
    fi
    if ! quitar_pendiente "$u" "$uid"; then
      echo 'ADVERTENCIA: fecha cambiada, pero el control horario anterior sigue pendiente.'
      echo 'No utilices la cuenta sin revisar ese registro.'
      exit 1
    fi
  ) 9>"$LOCK" || return 0

  logger -t rdz-usuarios "Renovada por dias: $u"
  echo "Cuenta $u renovada hasta $fecha."
  estado=$(passwd -S "$u" | awk '{print $2}')
  if [[ "$estado" == L* ]]; then
    echo 'La contraseña de esta cuenta esta bloqueada.'
    read -r -p 'Desbloquear la contraseña existente? (escribe SI): ' confirm
    if [[ "$confirm" == SI ]]; then
      passwd -u "$u" || echo 'No se pudo desbloquear. Revisa Rufu.'
    fi
  fi
}

eliminar() {
  local u="$1" uid="$2" confirm
  echo "Vas a eliminar $u de Linux. No se borrara su directorio personal."
  while true; do
    read -r -p "Eliminar usuario $u? (s/n): " confirm || { echo 'Cancelado.'; return 0; }
    case "${confirm,,}" in
      s) break ;;
      n|'') echo 'Cancelado.'; return 0 ;;
      *) echo 'Opcion invalida: escribe s o n.' ;;
    esac
  done

  mkdir -p /var/lib/rdz-demos
  chmod 700 /var/lib/rdz-demos
  (
    flock -x 9
    if ! es_rufu "$u" "$uid"; then
      echo 'La cuenta cambio o ya no existe. Cancelado.'
      exit 1
    fi
    if pgrep -u "$u" >/dev/null 2>&1; then
      echo 'El usuario tiene procesos activos. No se elimino.'
      exit 1
    fi
    if ! userdel "$u"; then
      echo 'No se pudo eliminar. Revisa sus conexiones.'
      exit 1
    fi
    if ! quitar_pendiente "$u" "$uid"; then
      echo 'ATENCION: quedo un registro de vencimiento anterior; no reutilices inmediatamente el nombre.'
    fi
  ) 9>"$LOCK" || return 0
  logger -t rdz-usuarios "Eliminada cuenta: $u"
  echo "Usuario $u eliminado."
}

while true; do
  echo
  echo '=========================================='
  echo ' BUSCADOR DE USUARIOS - ADMRufu 2.0'
  echo '=========================================='
  echo '1) Buscar usuario / renovar / eliminar'
  echo '2) Salir'
  read -r -p 'Opcion: ' op || exit 0
  case "$op" in
    2) exit 0 ;;
    1)
      read -r -p 'Nombre o parte del usuario: ' buscar
      if [[ -z "$buscar" || ${#buscar} -gt 40 ]]; then
        echo 'Escribe entre 1 y 40 caracteres.'
        continue
      fi
      resultados=()
      while IFS=: read -r u x uid gid gecos home shell; do
        if [[ "$uid" =~ ^[0-9]+$ ]] && (( uid >= 1000 )) &&
           [[ "$shell" == /bin/false && "$gecos" =~ ^[0-9]+, ]] &&
           [[ "${u,,}" == *"${buscar,,}"* ]]; then
          resultados+=("$u")
        fi
      done < <(getent passwd)
      if (( ${#resultados[@]} == 0 )); then
        echo 'No se encontraron usuarios de Rufu.'
        continue
      fi
      echo 'Resultados:'
      for i in "${!resultados[@]}"; do
        printf '%3d) %s\n' "$((i + 1))" "${resultados[$i]}"
      done
      read -r -p 'Numero de cuenta (0 cancela): ' num
      if [[ ! "$num" =~ ^[0-9]{1,5}$ ]] ||
         (( 10#$num < 1 || 10#$num > ${#resultados[@]} )); then
        echo 'Seleccion cancelada.'
        continue
      fi
      u="${resultados[$((10#$num - 1))]}"
      if ! es_rufu "$u"; then
        echo 'La cuenta ya no cumple el formato esperado.'
        continue
      fi
      uid=$(id -u "$u")
      while es_rufu "$u" "$uid"; do
        mostrar "$u"
        echo '1) Renovar por DIAS  2) Eliminar  3) Volver  4) Salir'
        read -r -p 'Opcion: ' accion || exit 0
        case "$accion" in
          1) renovar "$u" "$uid" ;;
          2) eliminar "$u" "$uid"; break ;;
          3) break ;;
          4) exit 0 ;;
          *) echo 'Opcion invalida.' ;;
        esac
      done
      ;;
    *) echo 'Opcion invalida.' ;;
  esac
done
USUARIOS

bash -n "$STAGE/demos"
bash -n "$STAGE/usuarios"
STAMP=$(date +%Y%m%d-%H%M%S)
for nombre in demos usuarios; do
  destino="/usr/local/bin/$nombre"
  if [[ -e "$destino" ]]; then
    cp -a -- "$destino" "${destino}.bak-${STAMP}"
  fi
  install -m 700 "$STAGE/$nombre" "$destino"
done

echo 'Instalado correctamente.'
echo 'Usa: demos    (creacion por dias)'
echo 'Usa: usuarios (buscar, renovar por dias, eliminar)'
echo 'No se modifico el menu original de Rufu.'
if [[ -s /var/lib/rdz-demos/pendientes.tsv ]]; then
  echo 'AVISO: hay DEMOS antiguas por horas pendientes.'
  echo 'El temporizador se conserva para que sigan venciendo correctamente.'
else
  echo 'El temporizador anterior puede quedar activo sin afectar las nuevas demos por dias.'
fi
