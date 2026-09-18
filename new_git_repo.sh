#!/bin/bash
# MAUVADAO
# Versão: 1.0.0
# Script para iniciar um repositorio git local e sincronizar com um
# repositorio ja existente no GitHub (repo vazio criado antes pelo site).

clear

# Pegando o username automaticamente.
GH_USERNAME=$(ssh -T git@github.com 2>&1 | grep -oP 'Hi \K[^!]+' || gh api user --jq .login)
[[ -n "$GH_USERNAME" ]] && {
GITHUB_USER="$GH_USERNAME"
} || {
GITHUB_USER="mauvadao4g"
}

BASE="$(basename "$(pwd)")"
[[ -n "$BASE" ]] && {
REPO_NAME="$BASE"
} || {
echo -e  "\e[1;31mNome Do Repositorio Vazio\e[0m"
exit 0
}

REMOTE_URL="git@github.com:${GITHUB_USER}/${REPO_NAME}.git"
BRANCH="main"

msg() {
    local color="$1"
    local text="$2"
    case "$color" in
        green) tput setaf 2 2>/dev/null ;;
        yellow) tput setaf 3 2>/dev/null ;;
        red) tput setaf 1 2>/dev/null ;;
        *) tput sgr0 2>/dev/null ;;
    esac
    echo "$text"
    tput sgr0 2>/dev/null
}

# Verifica se o Git está instalado
if ! command -v git &>/dev/null; then
    msg red "Erro: Git não está instalado. Por favor, instale-o antes de usar este script."
    exit 1
fi

# Função para verificar conexão SSH com o GitHub
verificar_ssh_github() {
    msg yellow "Verificando conexão SSH com o GitHub..."
    if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
        msg green "Conexão SSH com o GitHub está funcionando corretamente!"
    else
        msg red "Falha na conexão SSH com o GitHub. Verifique sua chave SSH e tente novamente."
        exit 1
    fi
}

verificar_ssh_github

DIR="$(pwd)"
git config --global --add safe.directory "$DIR" >/dev/null 2>&1

# Se ainda não é um repositorio git, inicializa
if [ ! -d ".git" ]; then
    msg yellow "Inicializando repositorio git local..."
    git init || { msg red "Erro ao inicializar repositorio."; exit 1; }
    git checkout -b "$BRANCH" >/dev/null 2>&1
else
    msg yellow "Repositorio git ja existe, pulando 'git init'."
fi

# Garante que a branch atual se chame $BRANCH
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
    git branch -M "$BRANCH"
fi

# Configura (ou corrige) o remote 'origin'
if git remote get-url origin >/dev/null 2>&1; then
    msg yellow "Remote 'origin' ja configurado, atualizando URL..."
    git remote set-url origin "$REMOTE_URL"
else
    msg yellow "Adicionando remote 'origin' -> $REMOTE_URL"
    git remote add origin "$REMOTE_URL"
fi

# Adiciona e commita arquivos, se houver algo para commitar
git add -A

if git diff --cached --quiet; then
    msg yellow "Nada novo para commitar."
else
    msg green "Realizando commit inicial..."
    git commit -m "Commit inicial" || { msg red "Erro ao realizar commit."; exit 1; }
fi

# Envia para o GitHub
msg green "Enviando alterações para o repositorio remoto..."
git push -u origin "$BRANCH" || { msg red "Erro ao enviar alterações."; exit 1; }

msg green "Processo concluido com sucesso!"
echo -ne "\e[38;5;188mCommit:\e[0m "
git log --oneline | head -n1
