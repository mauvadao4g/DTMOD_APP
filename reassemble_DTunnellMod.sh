#!/bin/bash
# Remonta o DTunnellMod.zip a partir das partes DTunnellMod.zip.partNN
set -e
cd "$(dirname "$0")"
cat DTunnellMod.zip.part* > DTunnellMod.zip
echo "DTunnellMod.zip remontado com sucesso."
