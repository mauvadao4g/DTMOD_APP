#!/bin/bash
###############################################################################
# INSTALADOR AUTOMÁTICO - PANEL DTUNNEL (Ubuntu VPS)
#
# 1. Actualiza el sistema
# 2. Instala Node.js, npm, Java 17, unzip, curl, ufw
# 3. Instala la librería compartida (/etc/dtm/lib.sh) y el comando `dtm`
# 4. Descarga y arranca el panel con PM2 (autodetecta el puerto real)
# 5. (Opcional) Configura Nginx + SSL con dominio propio (o IP:Puerto si el
#    puerto 80 ya está en uso por otro servicio)
#
# Uso:
#   chmod +x install.sh
#   sudo ./install.sh
#
# Después de instalado, gestiona todo con el comando `dtm`.
###############################################################################

set -euo pipefail

# ------------------------- CONFIG -------------------------
APP_NAME="dtunnel"
APP_DIR="/opt/${APP_NAME}"
ZIP_URL="https://www.dropbox.com/scl/fi/1e2eaoixnnppix3b7twq7/DTunnellMod.zip?rlkey=lofl9u825zumy32tl90x5l972&st=fqbtn214&dl=1"
APP_PORT="3000"
NODE_MAJOR="20"
ENTRYPOINT="src/index.ts"
DOMAIN=""
MODE="none"
EXPOSE_PORT=""
CERT_EMAIL=""

DTM_CONF_DIR="/etc/dtm"

if [[ $EUID -ne 0 ]]; then
   echo "Este script debe ejecutarse como root (usa: sudo ./install.sh)"
   exit 1
fi

# ------------------------- ESCRIBIR LIBRERÍA COMPARTIDA (embebida) -------------------------
mkdir -p "${DTM_CONF_DIR}"
cat > "${DTM_CONF_DIR}/lib.sh" <<'LIBEOF'
#!/bin/bash
###############################################################################
# /etc/dtm/lib.sh
# Librería compartida del panel DTunnel. La usan tanto install.sh (primera
# instalación) como el comando `dtm` (menú de gestión). Toda la lógica de
# instalar / reinstalar / desinstalar / cambiar dominio-puerto vive UNA sola
# vez aquí para que ambos scripts se comporten siempre igual.
###############################################################################

DTM_CONF_DIR="/etc/dtm"
DTM_CONF="${DTM_CONF_DIR}/dtm.conf"
DTM_LOG="/var/log/dtm.log"
mkdir -p "$(dirname "${DTM_LOG}")" 2>/dev/null
touch "${DTM_LOG}" 2>/dev/null || true

# ------------------------- COLORES (estilo senior) -------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()  { echo -e "${BOLD}${BLUE}[*]${NC} $1"; }
ok()   { echo -e "${BOLD}${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${BOLD}${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${BOLD}${RED}[ERROR]${NC} $1"; }

# Encabezado de sección, para separar visualmente cada fase del proceso.
step() { echo -e "\n${BOLD}${CYAN}▶ $1${NC}"; }

banner() {
    echo -e "${BOLD}${CYAN}======================================================${NC}"
    echo -e "${BOLD}${CYAN}   $1${NC}"
    echo -e "${BOLD}${CYAN}======================================================${NC}"
}

# Pregunta s/n unificada. Uso: if confirm "¿Hacer tal cosa? [s/n]: "; then ...
# Acepta s/si/sí/y/yes (en cualquier combinación de mayúsculas/minúsculas) como SÍ.
confirm() {
    local prompt="$1"
    local ans
    read -rp "${prompt}" ans
    ans="${ans,,}"
    [[ "${ans}" == "s" || "${ans}" == "si" || "${ans}" == "sí" || "${ans}" == "y" || "${ans}" == "yes" ]]
}

# Devuelve "dtm" si el usuario ya opera como root nativo, o "sudo dtm" si
# llegó a root vía sudo desde un usuario normal de Ubuntu.
dtm_cmd_hint() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        echo "sudo dtm"
    else
        echo "dtm"
    fi
}

# ------------------------- CONFIG -------------------------
dtm_load_config() {
    if [[ -f "${DTM_CONF}" ]]; then
        # shellcheck disable=SC1090
        source "${DTM_CONF}"
    else
        err "No se encontró ${DTM_CONF}. ¿El panel está instalado?"
        return 1
    fi
}

dtm_save_config() {
    mkdir -p "${DTM_CONF_DIR}"
    cat > "${DTM_CONF}" <<EOF
APP_NAME="${APP_NAME}"
APP_DIR="${APP_DIR}"
ZIP_URL="${ZIP_URL}"
ENTRYPOINT="${ENTRYPOINT}"
APP_PORT="${APP_PORT}"
DOMAIN="${DOMAIN:-}"
MODE="${MODE:-none}"
EXPOSE_PORT="${EXPOSE_PORT:-}"
CERT_EMAIL="${CERT_EMAIL:-}"
EOF
}

# ------------------------- DESCARGA + BUILD -------------------------
dtm_download_app() {
    local zip_file="/tmp/${APP_NAME}_dtm.zip"
    log "Baixando o painel da origem configurada..."
      # Se existit: baixar_dtmod.sh  -> use ele.
     [[ -f baixar_dtmod.sh ]] && {
      bash baixar_dtmod.sh
	}  || {
     # Se nao baixa direto via wget
           if ! wget --show-progress -qO "${zip_file}" "${ZIP_URL}" >> "${DTM_LOG}" 2>&1; then
                echo "Erro ao baixar o ${zip_file}"
                exit 1
           fi
	}

    if [[ ! -s "${zip_file}" ]]; then
        err "La descarga falló o el archivo está vacío. Revisa ${DTM_LOG}."
        return 1
    fi

    local tmp_extract
    tmp_extract="$(mktemp -d)"
    unzip -q -o "${zip_file}" -d "${tmp_extract}" >> "${DTM_LOG}" 2>&1

    local root_items=("${tmp_extract}"/*)
    local src_dir
    if [[ ${#root_items[@]} -eq 1 && -d "${root_items[0]}" ]]; then
        src_dir="${root_items[0]}"
    else
        src_dir="${tmp_extract}"
    fi

    mkdir -p "${APP_DIR}"
    rm -rf "${APP_DIR:?}"/*
    cp -a "${src_dir}/." "${APP_DIR}/"
    rm -rf "${tmp_extract}" "${zip_file}"
    ok "Painel baixado e extraído em ${APP_DIR}."
}

dtm_npm_install() {
    cd "${APP_DIR}" || return 1
    if [[ ! -f package.json ]]; then
        err "No se encontró package.json en ${APP_DIR}."
        return 1
    fi
    log "Instalando dependências npm..."
    npm install >> "${DTM_LOG}" 2>&1
    if [[ ! -x "${APP_DIR}/node_modules/.bin/tsx" ]]; then
        npm install tsx --save >> "${DTM_LOG}" 2>&1
    fi
    ok "Dependencias npm instaladas."
}

# ------------------------- PM2 -------------------------
dtm_start_app() {
    if ! command -v pm2 >/dev/null 2>&1; then
        log "Instalando o PM2 globalmente..."
        npm install -g pm2 >> "${DTM_LOG}" 2>&1
    fi
    cd "${APP_DIR}" || return 1
    log "Inicialização '${APP_NAME}' com PM2..."
    pm2 delete "${APP_NAME}" >> "${DTM_LOG}" 2>&1 || true
    pm2 start "${ENTRYPOINT}" --name "${APP_NAME}" --interpreter "${APP_DIR}/node_modules/.bin/tsx" >> "${DTM_LOG}" 2>&1
    pm2 save >> "${DTM_LOG}" 2>&1
    pm2 startup systemd -u root --hp /root >> "${DTM_LOG}" 2>&1 || true
    ok "Painel '${APP_NAME}' rodando com PM2."
}

dtm_detect_port() {
    log "Autodetectando a porta real do aplicativo..."
    sleep 4
    local detected=""
    local log_file="/root/.pm2/logs/${APP_NAME}-out.log"

    if [[ -f "${log_file}" ]]; then
        detected=$(grep -oE 'https?://[^ ]*:[0-9]+' "${log_file}" | tail -n1 | grep -oE '[0-9]+$' || true)
    fi

    if [[ -z "${detected}" && -f "${APP_DIR}/.env" ]]; then
        detected=$(grep -E '^PORT=' "${APP_DIR}/.env" | tail -n1 | cut -d= -f2 | tr -d '[:space:]"'"'"'' || true)
    fi

    if [[ -z "${detected}" ]]; then
        local node_pid
        node_pid=$(pm2 jlist 2>/dev/null | APP_NAME="${APP_NAME}" node -e '
            let data = "";
            process.stdin.on("data", (c) => { data += c; });
            process.stdin.on("end", () => {
                try {
                    const apps = JSON.parse(data);
                    const app = apps.find((a) => a.name === process.env.APP_NAME);
                    if (app && app.pid) console.log(app.pid);
                } catch (e) {}
            });
        ' 2>/dev/null || true)
        if [[ -n "${node_pid}" ]]; then
            detected=$(ss -tlnp 2>/dev/null | grep "pid=${node_pid}" | grep -oE ':[0-9]+ ' | tr -d ': ' | head -n1 || true)
        fi
    fi

    if [[ -n "${detected}" && "${detected}" != "${APP_PORT}" ]]; then
        ok "Porta real detectada: ${detected} (é atualizado a partir de ${APP_PORT})."
        APP_PORT="${detected}"
    elif [[ -n "${detected}" ]]; then
        ok "Puerto confirmado: ${APP_PORT}."
    else
        warn "No se pudo autodetectar el puerto; se mantiene ${APP_PORT}. Verifica con: pm2 logs ${APP_NAME}"
    fi

    ufw allow "${APP_PORT}/tcp" >> "${DTM_LOG}" 2>&1 || true
    dtm_save_config
}

# ------------------------- VERIFICACIÓN DE PUERTO 80 -------------------------
# Devuelve por stdout una descripción del proceso que ocupa el puerto 80, o
# vacío si está libre (o si lo ocupa nuestro propio nginx, lo cual no cuenta
# como conflicto porque lo vamos a reconfigurar nosotros mismos).
dtm_port80_owner() {
    local line
    line=$(ss -tlnp 2>/dev/null | awk '$4 ~ /:80$/ {print}')
    if [[ -z "${line}" ]]; then
        echo ""
        return
    fi
    if echo "${line}" | grep -qi 'nginx'; then
        echo ""
        return
    fi
    local proc pid
    proc=$(echo "${line}" | grep -oE '"[^"]+"' | head -n1 | tr -d '"')
    pid=$(echo "${line}" | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2)
    if [[ -n "${proc}" ]]; then
        echo "${proc} (pid ${pid:-?})"
    else
        echo "un proceso desconocido"
    fi
}

# ------------------------- NGINX -------------------------
dtm_remove_nginx_site() {
    rm -f "/etc/nginx/sites-enabled/${APP_NAME}"
    rm -f "/etc/nginx/sites-available/${APP_NAME}"
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >> "${DTM_LOG}" 2>&1 && systemctl reload nginx >> "${DTM_LOG}" 2>&1 || true
    fi
}

dtm_configure_nginx_domain() {
    local domain="$1"
    local email="$2"
    local prev_mode="${MODE:-none}"
    local prev_expose_port="${EXPOSE_PORT:-}"

    # ---- Verificación de puerto 80 antes de tocar nada ----
    local owner
    owner="$(dtm_port80_owner)"
    if [[ -n "${owner}" ]]; then
        warn "El puerto 80 está siendo usado por: ${owner}"
        warn "Nginx necesita el puerto 80 libre para emitir el certificado SSL del Panel Con Dominio."
        if confirm "¿Quieres usar Panel Con IP:Port en su lugar? [s/n]: "; then
            local fallback_port
            read -rp "¿En qué puerto quieres exponer el panel vía IP (sin SSL)? [ej: 8080]: " fallback_port
            if [[ -z "${fallback_port}" || ! "${fallback_port}" =~ ^[0-9]+$ ]]; then
                err "Puerto inválido. Cancelado."
                return 1
            fi
            dtm_configure_nginx_ip "${fallback_port}"
            return $?
        else
            err "Cancelado. Para usar el Panel Con Dominio primero debes liberar el puerto 80"
            err "(detén o desinstala: ${owner}) y volver a intentarlo."
            return 1
        fi
    fi

    log "Instalando Nginx e Certbot..."
    apt install -y nginx certbot python3-certbot-nginx >> "${DTM_LOG}" 2>&1

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    dtm_remove_nginx_site

    log "Criando configuração do Nginx para ${domain}..."
    cat > "/etc/nginx/sites-available/${APP_NAME}" <<EOF
server {
    listen 80;
    server_name ${domain};

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
    ln -sf "/etc/nginx/sites-available/${APP_NAME}" "/etc/nginx/sites-enabled/${APP_NAME}"
    [[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default

    nginx -t >> "${DTM_LOG}" 2>&1
    systemctl restart nginx >> "${DTM_LOG}" 2>&1
    systemctl enable nginx >> "${DTM_LOG}" 2>&1 || true

    ufw allow 80/tcp >> "${DTM_LOG}" 2>&1 || true
    ufw allow 443/tcp >> "${DTM_LOG}" 2>&1 || true

    log "Gerando certificado SSL com Let's Encrypt..."
    certbot --nginx -d "${domain}" --non-interactive --agree-tos -m "${email}" --redirect >> "${DTM_LOG}" 2>&1

    DOMAIN="${domain}"
    CERT_EMAIL="${email}"
    MODE="domain"
    EXPOSE_PORT=""
    dtm_save_config

    if [[ "${prev_mode}" == "ip" && -n "${prev_expose_port}" ]]; then
        ufw delete allow "${prev_expose_port}/tcp" >> "${DTM_LOG}" 2>&1 || true
    fi

    ok "Dominio configurado: https://${domain}"
}

dtm_configure_nginx_ip() {
    local expose_port="$1"
    local prev_mode="${MODE:-none}"
    local prev_expose_port="${EXPOSE_PORT:-}"

    log "Instalando nginx (si falta)..."
    apt install -y nginx >> "${DTM_LOG}" 2>&1

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    dtm_remove_nginx_site

    log "Creando configuración nginx sin SSL en el puerto ${expose_port}..."
    cat > "/etc/nginx/sites-available/${APP_NAME}" <<EOF
server {
    listen ${expose_port};
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
    ln -sf "/etc/nginx/sites-available/${APP_NAME}" "/etc/nginx/sites-enabled/${APP_NAME}"
    [[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default

    nginx -t >> "${DTM_LOG}" 2>&1
    systemctl restart nginx >> "${DTM_LOG}" 2>&1

    ufw allow "${expose_port}/tcp" >> "${DTM_LOG}" 2>&1 || true

    MODE="ip"
    EXPOSE_PORT="${expose_port}"
    DOMAIN=""
    dtm_save_config

    if [[ "${prev_mode}" == "ip" && -n "${prev_expose_port}" && "${prev_expose_port}" != "${expose_port}" ]]; then
        ufw delete allow "${prev_expose_port}/tcp" >> "${DTM_LOG}" 2>&1 || true
    fi

    local server_ip
    server_ip=$(curl -s -4 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    ok "Panel accesible (sin SSL) en: http://${server_ip}:${expose_port}"
}

# ------------------------- REINSTALAR -------------------------
dtm_reinstall() {
    log "Reinstalando ${APP_NAME}..."
    dtm_download_app || return 1
    dtm_npm_install || return 1
    dtm_start_app || return 1
    dtm_detect_port

    if [[ "${MODE}" == "domain" && -n "${DOMAIN}" ]]; then
        log "Re-aplicando proxy nginx para el dominio actual (${DOMAIN})..."
        dtm_configure_nginx_domain "${DOMAIN}" "${CERT_EMAIL}"
    elif [[ "${MODE}" == "ip" && -n "${EXPOSE_PORT}" ]]; then
        log "Re-aplicando proxy nginx para IP:Puerto actual (${EXPOSE_PORT})..."
        dtm_configure_nginx_ip "${EXPOSE_PORT}"
    fi
    ok "Reinstalación completa."
}

# ------------------------- BASE DE DATOS (prisma/dev.db) -------------------------
# La DB vive en ${APP_DIR}/prisma/dev.db. Los backups se guardan aparte, en
# /etc/dtm/backups, para que sobrevivan a un "Reinstalar Panel" (que borra
# APP_DIR por completo) o a un "Reset DB Users".

dtm_backup_db() {
    local db_dir="${APP_DIR}/prisma"
    local db_path="${db_dir}/dev.db"

    if [[ ! -f "${db_path}" ]]; then
        err "No se encontró la base de datos en ${db_path}."
        return 1
    fi

    local backup_dir="${DTM_CONF_DIR}/backups"
    mkdir -p "${backup_dir}"
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local backup_file="${backup_dir}/dtunnel_db_${ts}.tar.gz"

    # Incluye journal/wal/shm si existen, para no perder transacciones pendientes.
    local files=()
    for f in dev.db dev.db-journal dev.db-wal dev.db-shm; do
        [[ -f "${db_dir}/${f}" ]] && files+=("${f}")
    done

    log "Respaldando base de datos (${db_path})..."
    tar -czf "${backup_file}" -C "${db_dir}" "${files[@]}" >> "${DTM_LOG}" 2>&1
    ok "Backup creado: ${backup_file}"
}

dtm_restore_db() {
    local backup_dir="${DTM_CONF_DIR}/backups"

    if [[ ! -d "${backup_dir}" ]] || [[ -z "$(ls -A "${backup_dir}" 2>/dev/null)" ]]; then
        err "No hay backups disponibles en ${backup_dir}."
        return 1
    fi

    local -a backups
    mapfile -t backups < <(ls -1t "${backup_dir}"/dtunnel_db_*.tar.gz 2>/dev/null)

    if [[ ${#backups[@]} -eq 0 ]]; then
        err "No hay backups disponibles en ${backup_dir}."
        return 1
    fi

    echo ""
    echo -e "${BOLD}${CYAN}Backups disponibles (más reciente primero):${NC}"
    local i=1
    for b in "${backups[@]}"; do
        echo -e "  ${GREEN}${i})${NC} $(basename "${b}")"
        i=$((i + 1))
    done
    echo -e "  ${GREEN}0)${NC} Cancelar"
    echo ""

    local choice
    read -rp "¿Cuál quieres restaurar?: " choice

    if [[ -z "${choice}" || "${choice}" == "0" || ! "${choice}" =~ ^[0-9]+$ || "${choice}" -gt ${#backups[@]} ]]; then
        warn "Cancelado."
        return 0
    fi

    local selected="${backups[$((choice - 1))]}"
    warn "Esto sobreescribirá la base de datos actual con: $(basename "${selected}")"
    if ! confirm "¿Confirmas la restauración? [s/n]: "; then
        warn "Cancelado."
        return 0
    fi

    local db_dir="${APP_DIR}/prisma"
    mkdir -p "${db_dir}"

    log "Deteniendo el panel antes de restaurar..."
    pm2 stop "${APP_NAME}" >> "${DTM_LOG}" 2>&1 || true

    rm -f "${db_dir}/dev.db" "${db_dir}/dev.db-journal" "${db_dir}/dev.db-wal" "${db_dir}/dev.db-shm"

    log "Restaurando $(basename "${selected}")..."
    tar -xzf "${selected}" -C "${db_dir}" >> "${DTM_LOG}" 2>&1

    log "Reiniciando el panel..."
    pm2 restart "${APP_NAME}" >> "${DTM_LOG}" 2>&1 \
        || pm2 start "${ENTRYPOINT}" --name "${APP_NAME}" --interpreter "${APP_DIR}/node_modules/.bin/tsx" >> "${DTM_LOG}" 2>&1

    ok "Base de datos restaurada desde $(basename "${selected}")."
}

dtm_reset_db() {
    local db_dir="${APP_DIR}/prisma"
    local db_path="${db_dir}/dev.db"

    warn "Esto BORRARÁ todos los usuarios y datos de la base de datos, y recreará el esquema vacío."
    if ! confirm "¿Confirmas el reseteo total de la base de datos? [s/n]: "; then
        warn "Cancelado."
        return 0
    fi

    if [[ -f "${db_path}" ]]; then
        if confirm "¿Quieres hacer un backup antes de resetear? [s/n]: "; then
            dtm_backup_db || warn "No se pudo crear el backup; se continúa de todas formas."
        else
            warn "Continuando sin backup previo."
        fi
    fi

    log "Deteniendo el panel..."
    pm2 stop "${APP_NAME}" >> "${DTM_LOG}" 2>&1 || true

    rm -f "${db_dir}/dev.db" "${db_dir}/dev.db-journal" "${db_dir}/dev.db-wal" "${db_dir}/dev.db-shm"

    log "Recreando tablas con Prisma (db push --accept-data-loss)..."
    local prisma_cli="${APP_DIR}/node_modules/prisma/build/index.js"
    if [[ -f "${prisma_cli}" ]]; then
        (cd "${APP_DIR}" && node "${prisma_cli}" db push --accept-data-loss) >> "${DTM_LOG}" 2>&1
    else
        (cd "${APP_DIR}" && npx --yes prisma db push --accept-data-loss) >> "${DTM_LOG}" 2>&1
    fi

    log "Reiniciando el panel..."
    pm2 restart "${APP_NAME}" >> "${DTM_LOG}" 2>&1 \
        || pm2 start "${ENTRYPOINT}" --name "${APP_NAME}" --interpreter "${APP_DIR}/node_modules/.bin/tsx" >> "${DTM_LOG}" 2>&1

    ok "Base de datos reseteada: usuarios y datos eliminados, esquema recreado vacío."
}

dtm_delete_backup() {
    local backup_dir="${DTM_CONF_DIR}/backups"

    if [[ ! -d "${backup_dir}" ]] || [[ -z "$(ls -A "${backup_dir}" 2>/dev/null)" ]]; then
        err "No hay backups disponibles en ${backup_dir}."
        return 1
    fi

    local -a backups
    mapfile -t backups < <(ls -1t "${backup_dir}"/dtunnel_db_*.tar.gz 2>/dev/null)

    if [[ ${#backups[@]} -eq 0 ]]; then
        err "No hay backups disponibles en ${backup_dir}."
        return 1
    fi

    echo ""
    echo -e "${BOLD}${CYAN}Backups disponibles (más reciente primero):${NC}"
    local i=1
    for b in "${backups[@]}"; do
        echo -e "  ${GREEN}${i})${NC} $(basename "${b}")"
        i=$((i + 1))
    done
    echo -e "  ${GREEN}a)${NC} Eliminar TODOS"
    echo -e "  ${GREEN}0)${NC} Cancelar"
    echo ""

    local choice
    read -rp "¿Cuál quieres eliminar?: " choice

    if [[ -z "${choice}" || "${choice}" == "0" ]]; then
        warn "Cancelado."
        return 0
    fi

    if [[ "${choice,,}" == "a" ]]; then
        if confirm "¿Confirmas eliminar TODOS los backups (${#backups[@]})? [s/n]: "; then
            rm -f "${backup_dir}"/dtunnel_db_*.tar.gz
            ok "Todos los backups fueron eliminados."
        else
            warn "Cancelado."
        fi
        return 0
    fi

    if [[ ! "${choice}" =~ ^[0-9]+$ || "${choice}" -gt ${#backups[@]} ]]; then
        err "Opción inválida. Cancelado."
        return 1
    fi

    local selected="${backups[$((choice - 1))]}"
    if confirm "¿Confirmas eliminar $(basename "${selected}")? [s/n]: "; then
        rm -f "${selected}"
        ok "Backup eliminado: $(basename "${selected}")"
    else
        warn "Cancelado."
    fi
}

# ------------------------- DESINSTALAR -------------------------
dtm_uninstall_all() {
    log "Deteniendo y eliminando proceso PM2..."
    pm2 delete "${APP_NAME}" >> "${DTM_LOG}" 2>&1 || true
    pm2 save >> "${DTM_LOG}" 2>&1 || true

    log "Eliminando configuración nginx..."
    dtm_remove_nginx_site

    log "Eliminando carpeta de la app (${APP_DIR})..."
    rm -rf "${APP_DIR:?}"

    log "Eliminando comando dtm y librería..."
    rm -f /usr/local/bin/dtm
    rm -rf "${DTM_CONF_DIR}"

    ok "Panel y panel menu (dtm) desinstalados por completo."
}
LIBEOF

# shellcheck disable=SC1091
source "${DTM_CONF_DIR}/lib.sh"

# A partir de aquí ya tenemos log/ok/warn/err/step/banner/confirm/DTM_LOG
trap 'err "Fallo en la línea $LINENO. Últimas líneas del log (${DTM_LOG}):"; tail -n 20 "${DTM_LOG}" 2>/dev/null; exit 1' ERR

if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
   warn "No se detectó Ubuntu. El script continuará, pero no está garantizado."
fi

: > "${DTM_LOG}"
banner "INSTALAÇÃO AUTOMÁTICA - PAINEL DTUNNEL MOD"
echo -e "${DIM}Detalhes completos de cada comando em: ${DTM_LOG}${NC}"

# ------------------------- 1. ACTUALIZAR SISTEMA -------------------------
step "1. Atualizando o sistema... aguarde"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt update -y >> "${DTM_LOG}" 2>&1
apt upgrade -y >> "${DTM_LOG}" 2>&1
ok "Sistema atualizado."

# ------------------------- 2. DEPENDENCIAS BASE -------------------------
step "2. Instalando dependências base"
log "curl, unzip, wget, gnupg, ufw..."
apt install -y curl unzip wget gnupg2 ca-certificates ufw software-properties-common >> "${DTM_LOG}" 2>&1
ok "Dependências base instaladas."

# ------------------------- 3. NODE.JS + NPM -------------------------
step "3. Node.js + npm"
NEED_NODE_INSTALL=1
if command -v node >/dev/null 2>&1; then
    CURRENT_NODE_MAJOR="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
    if [[ "${CURRENT_NODE_MAJOR}" -ge "${NODE_MAJOR}" ]] 2>/dev/null; then
        ok "Node.js ya está instalado ($(node -v)). Se omite instalación."
        NEED_NODE_INSTALL=0
    else
        warn "Node.js $(node -v) es más antiguo que el requerido (v${NODE_MAJOR}.x). Actualizando..."
    fi
fi
if [[ "${NEED_NODE_INSTALL}" -eq 1 ]]; then
    log "Instalando Node.js ${NODE_MAJOR}.x (NodeSource) + npm..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" 2>>"${DTM_LOG}" | bash - >> "${DTM_LOG}" 2>&1
    apt install -y nodejs >> "${DTM_LOG}" 2>&1
    ok "Node.js $(node -v) y npm $(npm -v) instaladas."
fi

# ------------------------- 4. JAVA (REQUERIDO PARA APKEDITOR) -------------------------
step "4. Java (solicitado pelo ApkEditor)"
NEED_JAVA_INSTALL=1
if command -v java >/dev/null 2>&1; then
    CURRENT_JAVA_MAJOR="$(java -version 2>&1 | head -n1 | grep -oE '"[0-9]+' | tr -d '"')"
    if [[ -n "${CURRENT_JAVA_MAJOR}" ]] && [[ "${CURRENT_JAVA_MAJOR}" -ge 17 ]] 2>/dev/null; then
        ok "Java ya está instalado (versión ${CURRENT_JAVA_MAJOR}). Se omite instalación."
        NEED_JAVA_INSTALL=0
    else
        warn "Java instalado es más antiguo que el requerido (17+). Instalando OpenJDK 17..."
    fi
fi
if [[ "${NEED_JAVA_INSTALL}" -eq 1 ]]; then
    apt install -y openjdk-17-jdk >> "${DTM_LOG}" 2>&1
    ok "Java instalada."
fi

# ------------------------- 5. FIREWALL BASE -------------------------
step "5. Firewall"
log "Abrindo porta ${APP_PORT}/tcp..."
ufw allow "${APP_PORT}/tcp" >> "${DTM_LOG}" 2>&1 || warn "No se pudo aplicar la regla ufw (¿ufw inactivo?)."
ok "Porta ${APP_PORT} ativado."

# ------------------------- 6. GUARDAR CONFIG INICIAL -------------------------
dtm_save_config

# ------------------------- 7. DESCARGAR + INSTALAR APP -------------------------
step "6. Baixando e instalando o painel"
dtm_download_app
dtm_npm_install

# ------------------------- 8. PM2 -------------------------
step "7. Começando com o PM2"
dtm_start_app
dtm_detect_port

# ------------------------- 9. INSTALAR COMANDO dtm -------------------------
step "8. Instalando o comando dtm (menu painel)"
cat > /usr/local/bin/dtm <<'DTMEOF'
#!/bin/bash
###############################################################################
# dtm - Panel Menu para gestionar el panel DTunnel
###############################################################################
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Ejecuta como root: sudo dtm"
    exit 1
fi

# shellcheck disable=SC1091
source /etc/dtm/lib.sh

dtm_pause() {
    echo ""
    read -rp "Presiona ENTER para volver al menú..." _
}

dtm_menu_once() {
    dtm_load_config || exit 1

    # Opción 3: si ya estás en modo IP:Puerto, "cambiar dominio" no aplica —
    # en su lugar se ofrece cambiar el puerto expuesto.
    # Opción 4: ofrece siempre el modo contrario al actual (domain <-> ip).
    if [[ "${MODE}" == "ip" ]]; then
        OPTION3_LABEL="Change Port Panel"
        OPTION3_MODE="port"
        OPTION4_LABEL="Change IP:Puerto to Domain"
        OPTION4_TARGET="domain"
    else
        OPTION3_LABEL="Change Domain Panel"
        OPTION3_MODE="domain"
        OPTION4_LABEL="Change Domain To IP:Port"
        OPTION4_TARGET="ip"
    fi

    clear
    banner "DTM - PAINEL MENU"
    echo -e " App        : ${BOLD}${APP_NAME}${NC}"
    echo -e " Pasta     : ${DIM}${APP_DIR}${NC}"
    echo -e " Porta app  : ${BOLD}${APP_PORT}${NC}"
    if [[ "${MODE}" == "domain" ]]; then
        echo -e " Acesso      : ${GREEN}https://${DOMAIN}${NC}"
    elif [[ "${MODE}" == "ip" ]]; then
        echo -e " Acceso      : ${YELLOW}IP:${EXPOSE_PORT} (sin SSL)${NC}"
    else
        echo -e " Acceso      : ${RED}no configurado (nginx no aplicado)${NC}"
    fi
    echo -e "${CYAN}======================================================${NC}"
    echo -e " ${GREEN}1)${NC} Reinstalar Painel"
    echo -e " ${GREEN}2)${NC} Desinstalar Painel e Script"
    echo -e " ${GREEN}3)${NC} ${OPTION3_LABEL}"
    echo -e " ${GREEN}4)${NC} ${OPTION4_LABEL}"
    echo -e "${DIM}------------------- Base de Dados -------------------${NC}"
    echo -e " ${GREEN}5)${NC} Backup DB Users"
    echo -e " ${GREEN}6)${NC} Restore DB Users"
    echo -e " ${GREEN}7)${NC} Reset DB Users"
    echo -e " ${GREEN}8)${NC} Excluir Backup"
    echo -e "${CYAN}======================================================${NC}"
    echo -e " ${GREEN}0)${NC} Sair"
    echo -e "${CYAN}======================================================${NC}"
    read -rp "Escolha uma opção: " OPTION

    case "${OPTION}" in
        1)
            if confirm "¿Reinstalar '${APP_NAME}' desde el origen configurado? [s/n]: "; then
                dtm_reinstall
            else
                warn "Cancelado."
            fi
            dtm_pause
            ;;
        2)
            echo ""
            warn "Esto eliminará el panel, PM2, la config de nginx, la carpeta ${APP_DIR}"
            warn "y el propio comando 'dtm'. Esta acción NO se puede deshacer."
            if confirm "¿Confirmas que quieres desinstalar TODO? [s/n]: "; then
                dtm_uninstall_all
                echo ""
                ok "Listo. El comando 'dtm' ya no está disponible."
                echo ""
                exit 0
            else
                warn "Cancelado."
                dtm_pause
            fi
            ;;
        3)
            if [[ "${OPTION3_MODE}" == "port" ]]; then
                read -rp "Nuevo puerto para exponer el panel vía IP (sin SSL) [ej: 8080]: " NEW_PORT
                if [[ -z "${NEW_PORT}" || ! "${NEW_PORT}" =~ ^[0-9]+$ ]]; then
                    err "Puerto inválido. Cancelado."
                elif confirm "¿Confirmas cambiar el puerto expuesto a ${NEW_PORT}? [s/n]: "; then
                    dtm_configure_nginx_ip "${NEW_PORT}"
                else
                    warn "Cancelado."
                fi
            else
                read -rp "Nuevo dominio (ej: panel.midominio.com): " NEW_DOMAIN
                read -rp "Correo para Let's Encrypt: " NEW_EMAIL
                if [[ -z "${NEW_DOMAIN}" || -z "${NEW_EMAIL}" ]]; then
                    err "Dominio o correo vacío. Cancelado."
                elif confirm "¿Confirmas configurar el dominio ${NEW_DOMAIN}? [s/n]: "; then
                    dtm_configure_nginx_domain "${NEW_DOMAIN}" "${NEW_EMAIL}"
                else
                    warn "Cancelado."
                fi
            fi
            dtm_pause
            ;;
        4)
            if [[ "${OPTION4_TARGET}" == "domain" ]]; then
                read -rp "Nuevo dominio (ej: panel.midominio.com): " NEW_DOMAIN
                read -rp "Correo para Let's Encrypt: " NEW_EMAIL
                if [[ -z "${NEW_DOMAIN}" || -z "${NEW_EMAIL}" ]]; then
                    err "Dominio o correo vacío. Cancelado."
                elif confirm "¿Confirmas pasar de IP:Puerto a dominio ${NEW_DOMAIN} con SSL? [s/n]: "; then
                    dtm_configure_nginx_domain "${NEW_DOMAIN}" "${NEW_EMAIL}"
                else
                    warn "Cancelado."
                fi
            else
                read -rp "¿En qué puerto quieres exponer el panel vía IP (sin SSL)? [ej: 8080]: " NEW_PORT
                if [[ -z "${NEW_PORT}" || ! "${NEW_PORT}" =~ ^[0-9]+$ ]]; then
                    err "Puerto inválido. Cancelado."
                elif confirm "¿Confirmas pasar de dominio a IP:${NEW_PORT} sin SSL? [s/n]: "; then
                    dtm_configure_nginx_ip "${NEW_PORT}"
                else
                    warn "Cancelado."
                fi
            fi
            dtm_pause
            ;;
        5)
            dtm_backup_db
            dtm_pause
            ;;
        6)
            dtm_restore_db
            dtm_pause
            ;;
        7)
            dtm_reset_db
            dtm_pause
            ;;
        8)
            dtm_delete_backup
            dtm_pause
            ;;
        0)
            exit 0
            ;;
        *)
            err "Opción inválida."
            dtm_pause
            ;;
    esac
}

while true; do
    dtm_menu_once
done
DTMEOF
chmod +x /usr/local/bin/dtm
DTM_HINT="$(dtm_cmd_hint)"
ok "Comando 'dtm' instalada. Executa '${DTM_HINT}' para abrir o menu do painel."

echo ""
banner "INSTALAÇÃO BASE CONCLUÍDA"
echo -e " Pasta do projeto : ${BOLD}${APP_DIR}${NC}"
echo -e " Porto interno       : ${BOLD}${APP_PORT}${NC}"
echo -e " Painel Menu           : ${BOLD}${GREEN}${DTM_HINT}${NC}"
echo -e " Credencial Do Admin"
echo -e " Usuário           : admindt"
echo -e " Senha           : 123456"
echo -e " Ver logs do aplicativo   : pm2 logs ${APP_NAME}"
echo -e "${CYAN}======================================================${NC}"
echo ""

# ------------------------- 10. SSL + DOMINIO (OPCIONAL) -------------------------
step "9. Dominio + HTTPS (opcional)"
if confirm "¿Deseja configurar um domínio + HTTPS (Nginx + Let's Encrypt) agora? [s/n]: "; then
    read -rp "Dominio a configurar (ex: dtunnel.seudomínio.com): " DOMAIN
    read -rp "E-mail para Let's Encrypt: " CERT_EMAIL

    if [[ -z "${DOMAIN}" || -z "${CERT_EMAIL}" ]]; then
        err "Dominio o correo vacío. Se omite la configuración SSL."
    else
        dtm_configure_nginx_domain "${DOMAIN}" "${CERT_EMAIL}" || true
        echo ""
        if [[ "${MODE}" == "domain" ]]; then
            banner "DOMINIO + SSL CONFIGURADOS"
            echo -e " ${GREEN}https://${DOMAIN}${NC}"
        elif [[ "${MODE}" == "ip" ]]; then
            banner "PANEL CON IP:PUERTO CONFIGURADO"
            echo -e " ${YELLOW}Puerto 80 estaba ocupado, se usó IP:${EXPOSE_PORT} en su lugar (sin SSL).${NC}"
        else
            warn "No se configuró dominio ni IP:Puerto. Puedes hacerlo después con '${DTM_HINT}' -> opción 3 o 4."
        fi
    fi
else
    warn "Configuración de dominio/SSL omitida."
    warn "Puedes acceder por IP:${APP_PORT} o usar '${DTM_HINT}' -> opción 4 más tarde."
fi

echo ""
ok "Instalação concluída. Use '${DTM_HINT}' para abrir o menu do painel."
