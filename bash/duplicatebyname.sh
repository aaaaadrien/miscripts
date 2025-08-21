#!/bin/bash

# Vérifier si deux arguments sont fournis
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 dossier1 dossier2"
    exit 1
fi

dossier1="$1"
dossier2="$2"

# Vérifier si les dossiers existent
if [ ! -d "$dossier1" ] || [ ! -d "$dossier2" ]; then
    echo "L'un des dossiers n'existe pas."
    exit 1
fi

# Parcourir tous les fichiers dans le dossier 1
echo "Fichiers dans $dossier1 qui existent dans $dossier2 :"
for fichier in "$dossier1"/*; do
    # Vérifier si c'est un fichier
    if [ -f "$fichier" ]; then
        nom_fichier=$(basename "$fichier")
        # Vérifier si le fichier existe dans le dossier 2
        if [ -e "$dossier2/$nom_fichier" ]; then
            echo "$nom_fichier"
            rm -i "$dossier2/$nom_fichier"
        fi
    fi
done
