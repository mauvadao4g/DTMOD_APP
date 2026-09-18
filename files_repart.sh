#!/bin/bash
# files_repart.sh - Divide ou junta arquivos em partes.
#
# Dividir: files_repart.sh [-b] <tamanho> <digitos> <file_pra_dividir>
#   Exe: files_repart.sh 40M 2 DTunnellMod.zip
#        -> gera DTunnellMod.zip.part00, DTunnellMod.zip.part01, ...
#
# Juntar: files_repart.sh -j <prefixo_das_partes>
#   Exe: files_repart.sh -j DTunnellMod.zip.part
#        -> junta DTunnellMod.zip.part* em DTunnellMod.zip

set -e

msg() {
    local color="$1"
    local text="$2"
    case "$color" in
        green) tput setaf 2 2>/dev/null ;;
        red) tput setaf 1 2>/dev/null ;;
        yellow) tput setaf 3 2>/dev/null ;;
        *) tput sgr0 2>/dev/null ;;
    esac
    echo "$text"
    tput sgr0 2>/dev/null
}

uso() {
    cat <<EOF
Uso:
  Dividir: $0 [-b] <tamanho> <digitos> <file_pra_dividir>
           Exe: $0 40M 2 DTunnellMod.zip

  Juntar:  $0 -j <prefixo_das_partes>
           Exe: $0 -j DTunnellMod.zip.part
EOF
    exit 1
}

[ "$#" -eq 0 ] && uso

if [ "$1" = "-j" ]; then
    prefixo="$2"
    [ -z "$prefixo" ] && uso

    partes=("${prefixo}"*)
    if [ ! -e "${partes[0]}" ]; then
        msg red "Erro: nenhuma parte encontrada com o prefixo '$prefixo'."
        exit 1
    fi

    destino="$prefixo"
    [[ "$destino" == *.part ]] && destino="${destino%.part}"
    [ "$destino" = "$prefixo" ] && destino="${prefixo}.joined"

    if [ -e "$destino" ]; then
        msg red "Erro: '$destino' ja existe. Remova ou renomeie antes de juntar."
        exit 1
    fi

    msg yellow "Juntando ${#partes[@]} parte(s) em '$destino'..."
    cat "${partes[@]}" > "$destino"
    msg green "Concluido: $destino"
    exit 0
fi

[ "$1" = "-b" ] && shift

tamanho="$1"
digitos="$2"
arquivo="$3"

[ -z "$tamanho" ] || [ -z "$digitos" ] || [ -z "$arquivo" ] && uso
[ -f "$arquivo" ] || { msg red "Erro: arquivo '$arquivo' nao encontrado."; exit 1; }
[[ "$digitos" =~ ^[0-9]+$ ]] || { msg red "Erro: digitos deve ser um numero."; exit 1; }

msg yellow "Dividindo '$arquivo' em partes de $tamanho..."
split -b "$tamanho" -d --suffix-length="$digitos" "$arquivo" "${arquivo}.part"
msg green "Concluido. Partes geradas:"
ls -la "${arquivo}".part*
