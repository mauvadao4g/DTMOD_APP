#!/bin/bash

EMAIL='mauvadao4g@gmail.com'
RANDOM_ID=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
FILE="git_${RANDOM_ID}"

# 1. Gera a chave
ssh-keygen -t ed25519 -f ~/.ssh/$FILE -C "$EMAIL" -N ""

# 2. Carrega o agente SSH
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/$FILE

# 3. Mostra a chave pública e copia pro clipboard
cat ~/.ssh/${FILE}.pub | xclip -sel clip

# 4. Instruções
cat <<EOF
------------------------------------------
              INSTRUÇÕES
------------------------------------------
Arquivo de chave privada: ~/.ssh/$FILE
Arquivo de chave pública: ~/.ssh/${FILE}.pub

Acesse: https://github.com/settings/keys
Clica em "New SSH Key"
Cola a chave que foi copiada para seu clipboard.
------------------------------------------
EOF


until ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"
do
    echo "Aguardando autenticacao SSH..."
    sleep 5
done

echo "Concluido com sucesso!"
