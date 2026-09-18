#!/bin/bash

URL='https://www.dropbox.com/scl/fi/1e2eaoixnnppix3b7twq7/DTunnellMod.zip?rlkey=lofl9u825zumy32tl90x5l972&st=fqbtn214&dl=1'
ARQUIVO='DTunnellMod.zip'

# ============================================================
# CORES
# ============================================================

VERDE='\033[1;32m'
AZUL='\033[1;34m'
CIANO='\033[1;36m'
AMARELO='\033[1;33m'
VERMELHO='\033[1;31m'
CINZA='\033[1;90m'
RESET='\033[0m'

# ============================================================
# DEPENDÊNCIA
# ============================================================

if ! command -v curl >/dev/null 2>&1; then
    echo -e "${VERMELHO}[FAIL]${RESET} curl não está instalado."
    exit 1
fi

# ============================================================
# TAMANHO DO TERMINAL / CAIXA
# ============================================================

COLS=$(tput cols 2>/dev/null || echo 80)
(( COLS > 78 )) && COLS=78

BOX_WIDTH=$((COLS - 2))
(( BOX_WIDTH < 30 )) && BOX_WIDTH=30

BAR_WIDTH=$((BOX_WIDTH - 42))
(( BAR_WIDTH < 20 )) && BAR_WIDTH=20

# ============================================================
# DESENHO DE CAIXA (largura dinâmica)
# ============================================================

repeat_char() {
    local n="$1" ch="$2" s=""
    printf -v s '%*s' "$n" ''
    echo "${s// /$ch}"
}

box_top()    { echo -e "${CIANO}╭$(repeat_char "$BOX_WIDTH" '─')╮${RESET}"; }
box_bottom() { echo -e "${CIANO}╰$(repeat_char "$BOX_WIDTH" '─')╯${RESET}"; }

box_line() {
    local cor="$1" texto="$2"
    local visible pad
    visible=$(echo -e "$texto" | sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g')
    pad=$((BOX_WIDTH - 1 - ${#visible}))
    (( pad < 0 )) && pad=0
    echo -e "${CIANO}│${RESET} ${cor}${texto}${RESET}$(repeat_char "$pad" ' ')${CIANO}│${RESET}"
}

# ============================================================
# FUNÇÕES AUXILIARES
# ============================================================

format_size() {
    numfmt --to=iec --suffix=B "$1" 2>/dev/null ||
        awk -v n="$1" '
        function human(x) {
            if (x >= 1073741824) return sprintf("%.1f GB", x/1073741824)
            if (x >= 1048576)    return sprintf("%.1f MB", x/1048576)
            if (x >= 1024)       return sprintf("%.1f KB", x/1024)
            return sprintf("%d B", x)
        }
        BEGIN { print human(n) }
        '
}

format_time() {
    local sec="$1"

    if (( sec < 0 )); then
        echo "--:--"
    elif (( sec >= 3600 )); then
        printf '%02d:%02d:%02d' \
            $((sec / 3600)) \
            $(((sec % 3600) / 60)) \
            $((sec % 60))
    else
        printf '%02d:%02d' \
            $((sec / 60)) \
            $((sec % 60))
    fi
}

percent_color() {
    local p="$1"
    if   (( p < 34 )); then echo -ne "$VERMELHO"
    elif (( p < 67 )); then echo -ne "$AMARELO"
    else                    echo -ne "$VERDE"
    fi
}

# ============================================================
# LIMPEZA / INTERRUPÇÃO
# ============================================================

CURL_PID=""

cleanup() {
    tput cnorm 2>/dev/null
    if [[ -n "$CURL_PID" ]] && kill -0 "$CURL_PID" 2>/dev/null; then
        kill "$CURL_PID" 2>/dev/null
        wait "$CURL_PID" 2>/dev/null
    fi
}

on_interrupt() {
    cleanup
    echo
    echo -e "${VERMELHO}[CANCELADO]${RESET} Download interrompido pelo usuário."
    rm -f "$ARQUIVO"
    exit 130
}

trap on_interrupt INT TERM
trap cleanup EXIT

# ============================================================
# LIMPA ARQUIVO PARCIAL
# ============================================================

rm -f "$ARQUIVO"

echo
box_top
box_line "$AZUL" "Baixando: $ARQUIVO"
box_bottom
echo

# ============================================================
# TAMANHO TOTAL (uma única consulta, antes de iniciar)
# ============================================================

TOTAL=$(curl -L --silent --show-error --head "$URL" 2>/dev/null |
    awk 'BEGIN{IGNORECASE=1}
         /^content-length:/ {
             gsub("\r","",$2)
             total=$2
         }
         END { print total }')

[[ "$TOTAL" =~ ^[0-9]+$ ]] || TOTAL=0

# ============================================================
# DOWNLOAD
# ============================================================

START=$(date +%s)

curl -L \
    --fail \
    --silent \
    --show-error \
    --output "$ARQUIVO" \
    "$URL" &

CURL_PID=$!

# ============================================================
# MONITORAMENTO
# ============================================================

tput civis 2>/dev/null

while kill -0 "$CURL_PID" 2>/dev/null; do

    SIZE=0
    [[ -f "$ARQUIVO" ]] && SIZE=$(stat -c%s "$ARQUIVO" 2>/dev/null || echo 0)

    NOW=$(date +%s)
    ELAPSED=$((NOW - START))

    if (( ELAPSED > 0 )); then
        SPEED=$((SIZE / ELAPSED))
    else
        SPEED=0
    fi

    if (( TOTAL > 0 )); then

        PERCENT=$((SIZE * 100 / TOTAL))
        (( PERCENT > 100 )) && PERCENT=100

        FILLED=$((BAR_WIDTH * PERCENT / 100))
        EMPTY=$((BAR_WIDTH - FILLED))

        BAR="$(repeat_char "$FILLED" '█')$(repeat_char "$EMPTY" '░')"

        if (( SPEED > 0 )); then
            ETA=$(( (TOTAL - SIZE) / SPEED ))
        else
            ETA=-1
        fi

        COR=$(percent_color "$PERCENT")

        printf "\r\033[K${COR}[%s]${RESET} %3d%%  %s / %s  %s/s  ETA %s" \
            "$BAR" \
            "$PERCENT" \
            "$(format_size "$SIZE")" \
            "$(format_size "$TOTAL")" \
            "$(format_size "$SPEED")" \
            "$(format_time "$ETA")"

    else

        printf "\r\033[K${VERDE}Baixando${RESET} %s  %s/s  ${CINZA}(tamanho total desconhecido)${RESET}" \
            "$(format_size "$SIZE")" \
            "$(format_size "$SPEED")"

    fi

    sleep 0.5
done

wait "$CURL_PID"
STATUS=$?
CURL_PID=""

tput cnorm 2>/dev/null

echo
echo

# ============================================================
# RESULTADO
# ============================================================

if (( STATUS == 0 )) && [[ -s "$ARQUIVO" ]]; then

    FINAL_SIZE=$(stat -c%s "$ARQUIVO")
    ELAPSED_TOTAL=$(( $(date +%s) - START ))

    box_top
    box_line "$VERDE" "[OK] Download concluído!"
    box_line "$RESET" "Arquivo: $ARQUIVO"
    box_line "$RESET" "Tamanho: $(format_size "$FINAL_SIZE")"
    box_line "$RESET" "Tempo:   $(format_time "$ELAPSED_TOTAL")"
    box_bottom

else

    echo -e "${VERMELHO}[FAIL]${RESET} Falha no download (curl saiu com código $STATUS)."

    rm -f "$ARQUIVO"

    exit 1
fi
