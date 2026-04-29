#!/bin/bash

# 1. Vérifier que le script est exécuté en tant que root
if [[ $EUID -ne 0 ]]; then
   echo "Ce script doit être exécuté en tant que root (ou via sudo)."
   exit 1
fi


echo "Suggestion de mot de passe : "
< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 16; echo

# 2. Demander les informations à l'utilisateur
read -p "Nom de l'utilisateur à créer : " DB_USER
read -p "Nom de la base de données à créer : " DB_NAME
read -p "Mot de passe de l'utilisateur : " DB_PASS
# mdp masque - read -s -p "Mot de passe de l'utilisateur : " DB_PASS
echo ""

# 3. Récupérer automatiquement le tri (collate) et le ctype de la base template1
# Cela évite l'erreur d'incompatibilité que tu as rencontrée.
TEMPLATE_COLLATE=$(sudo -u postgres psql -tAc "SELECT datcollate FROM pg_database WHERE datname='template1'")
TEMPLATE_CTYPE=$(sudo -u postgres psql -tAc "SELECT datctype FROM pg_database WHERE datname='template1'")

echo "Détection de la configuration système : Collate=$TEMPLATE_COLLATE, Ctype=$TEMPLATE_CTYPE"

# 4. Vérifier si l'utilisateur existe déjà
USER_EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'")

if [ "$USER_EXISTS" = "1" ]; then
    echo "L'utilisateur '$DB_USER' existe déjà."
else
    echo "Création de l'utilisateur '$DB_USER'..."
    sudo -u postgres psql -c "CREATE ROLE $DB_USER WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT -1 PASSWORD '$DB_PASS';"
fi

# 5. Vérifier si la base de données existe déjà
DB_EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")

if [ "$DB_EXISTS" = "1" ]; then
    echo "La base de données '$DB_NAME' existe déjà. Arrêt."
    exit 1
else
    echo "Création de la base de données '$DB_NAME'..."
    # Utilisation des variables détectées dynamiquement
    sudo -u postgres psql -c "CREATE DATABASE $DB_NAME WITH OWNER = $DB_USER ENCODING = 'UTF8' LC_COLLATE = '$TEMPLATE_COLLATE' LC_CTYPE = '$TEMPLATE_CTYPE' TABLESPACE = pg_default CONNECTION LIMIT = -1;"
fi

# 6. Gestion des permissions
echo "Sécurisation des accès..."
sudo -u postgres psql -d "$DB_NAME" -c "REVOKE ALL ON DATABASE $DB_NAME FROM PUBLIC;"
sudo -u postgres psql -d "$DB_NAME" -c "REVOKE ALL ON SCHEMA public FROM PUBLIC;"
sudo -u postgres psql -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"
sudo -u postgres psql -d "$DB_NAME" -c "GRANT ALL PRIVILEGES ON SCHEMA public TO $DB_USER;"

echo "L'opération est terminée avec succès pour $DB_NAME."
