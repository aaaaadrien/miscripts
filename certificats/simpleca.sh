#!/bin/bash

# ============================================================
#  simpleca.sh – Gestion complète PKI interne
#
#  Usage :
#    ./simpleca.sh --create-ca
#    ./simpleca.sh --install-ca
#    ./simpleca.sh --remove-ca
#    ./simpleca.sh --new-cert <fqdn> [fqdn2 ...]
#    ./simpleca.sh --squid-ca
# ============================================================

set -euo pipefail

# Helpers interactifs
REPLY=""
ask_default() {
    local prompt="$1"
    local default="$2"
    local result
    echo -n "? ${prompt} [${default}] : "
    read -r result
    REPLY="${result:-$default}"
}

MENU_RESULT=""
select_menu() {
    local title="$1"; shift
    local -a items=("$@")
    local n="${#items[@]}"
    local i=1

    echo ""
    echo "$title"
    for item in "${items[@]}"; do
        echo "  ${i}) ${item}"
        (( i++ ))
    done
    echo ""

    local choice
    while true; do
        echo -n "? Votre choix [1-${n}] : "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
            MENU_RESULT="${items[$((choice - 1))]}"
            return 0
        fi
        echo "[WARN]   Choix invalide, entrez un nombre entre 1 et ${n}."
    done
}

# Détection de la distribution
DISTRO=""
detect_distro() {
    DISTRO="$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}" || echo "unknown")"
}

is_rhel_family()   { [[ "$DISTRO" =~ ^(fedora|rhel|centos|rocky|almalinux|ol)$ ]]; }
is_debian_family() { [[ "$DISTRO" =~ ^(ubuntu|debian|linuxmint|pop|kali)$ ]]; }

# Chargement des CAs locales (répertoire CA/)
LOCAL_CAS=()
load_local_cas() {
    LOCAL_CAS=()
    [[ -d "CA" ]] || return 0
    while IFS= read -r dir; do
        local dname
        dname="$(basename "$dir")"
        [[ -f "${dir}/${dname}-ca.crt" ]] && LOCAL_CAS+=("$dname")
    done < <(find CA -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
}

# Chargement des CAs installées dans le système
INSTALLED_CAS=()
INSTALLED_CAS_PATHS=()
load_installed_cas() {
    INSTALLED_CAS=()
    INSTALLED_CAS_PATHS=()
    detect_distro

    local anchor_dir=""
    if is_rhel_family; then
        anchor_dir="/etc/pki/ca-trust/source/anchors"
    elif is_debian_family; then
        anchor_dir="/usr/local/share/ca-certificates"
    else
        echo "[ERREUR] Distribution '$DISTRO' non supportée." >&2; exit 1
    fi

    [[ -d "$anchor_dir" ]] || return 0

    while IFS= read -r f; do
        INSTALLED_CAS+=("$(basename "$f" .crt)")
        INSTALLED_CAS_PATHS+=("$f")
    done < <(find "$anchor_dir" -maxdepth 1 -name "*.crt" 2>/dev/null | sort)
}

#  --create-ca
cmd_create_ca() {
    echo ""
    echo "=== Création d'une nouvelle CA ==="
    echo ""

    ask_default "Domaine de la CA" "linuxtricks.lan"
    local domain="$REPLY"

    ask_default "Durée de validité de la CA (jours)" "3650"
    local ca_days="$REPLY"
    [[ "$ca_days" =~ ^[0-9]+$ && "$ca_days" -gt 0 ]] \
        || { echo "[ERREUR] Durée invalide : $ca_days" >&2; exit 1; }

    ask_default "Taille de la clé RSA (bits)" "4096"
    local key_bits="$REPLY"
    [[ "$key_bits" =~ ^(2048|4096|8192)$ ]] \
        || { echo "[ERREUR] Taille de clé invalide (valeurs acceptées : 2048, 4096, 8192)" >&2; exit 1; }

    local ca_dir="CA/${domain}"
    local ca_base="${ca_dir}/${domain}-ca"

    if [[ -f "${ca_base}.crt" ]]; then
        echo "[WARN]   Une CA existe déjà pour le domaine '${domain}'."
        echo -n "? Ecraser ? [o/N] : "
        read -r confirm
        [[ "$confirm" =~ ^[oO]$ ]] || { echo "[INFO]   Annulé."; return 0; }
    fi

    mkdir -p "$ca_dir"
    chmod 700 "$ca_dir"

    echo "[INFO]   Génération de la clé privée CA (RSA ${key_bits} bits)..."
    openssl genpkey -algorithm RSA \
        -aes256 \
        -out "${ca_base}.key" \
        -pkeyopt rsa_keygen_bits:"${key_bits}"
    chmod 600 "${ca_base}.key"

    local org="${domain%%.*}"
    cat > "${ca_base}.ext" << EOF
[ req ]
distinguished_name = req_distinguished_name
x509_extensions    = v3_ca
prompt             = no

[ req_distinguished_name ]
C  = FR
ST = BOURGOGNE
L  = DIJON
O  = ${org^^}
OU = ${org^^} CA
CN = ${domain} Root CA

[ v3_ca ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical,CA:TRUE
keyUsage               = critical,keyCertSign,cRLSign
EOF

    echo "[INFO]   Génération du certificat CA auto-signé (${ca_days} jours)..."
    openssl req -new -x509 \
        -key "${ca_base}.key" \
        -out "${ca_base}.crt" \
        -days "${ca_days}" \
        -sha256 \
        -config "${ca_base}.ext"
    chmod 644 "${ca_base}.crt"

    echo "[INFO]   Génération du PEM combiné (clé + certificat)..."
    cat "${ca_base}.key" "${ca_base}.crt" > "${ca_base}.pem"
    chmod 600 "${ca_base}.pem"

    echo "[INFO]   Vérification..."
    openssl verify -CAfile "${ca_base}.crt" "${ca_base}.crt"
    echo ""
    openssl x509 -in "${ca_base}.crt" -noout -subject -issuer -dates

    echo ""
    echo "[INFO]   CA '${domain}' créée avec succès"
    echo "[INFO]     ${ca_dir}/${domain}-ca.key  -> clé privée  (ne jamais distribuer)"
    echo "[INFO]     ${ca_dir}/${domain}-ca.crt  -> certificat  (à distribuer aux clients)"
    echo "[INFO]     ${ca_dir}/${domain}-ca.pem  -> PEM combiné (clé + cert)"
}

#  --install-ca
cmd_install_ca() {
    echo ""
    echo "=== Installation de la CA dans le magasin système ==="
    echo ""

    [[ $EUID -eq 0 ]] \
        || { echo "[ERREUR] Cette opération nécessite les droits root (sudo $0 --install-ca)." >&2; exit 1; }

    load_local_cas
    [[ ${#LOCAL_CAS[@]} -gt 0 ]] \
        || { echo "[ERREUR] Aucune CA locale trouvée dans CA/. Créez-en une avec : $0 --create-ca" >&2; exit 1; }

    local domain
    if [[ ${#LOCAL_CAS[@]} -eq 1 ]]; then
        domain="${LOCAL_CAS[0]}"
        echo "[INFO]   CA détectée : ${domain}"
    else
        select_menu "Quelle CA souhaitez-vous installer ?" "${LOCAL_CAS[@]}"
        domain="$MENU_RESULT"
    fi

    local ca_cert="CA/${domain}/${domain}-ca.crt"
    [[ -f "$ca_cert" ]] \
        || { echo "[ERREUR] Certificat CA introuvable : $ca_cert" >&2; exit 1; }

    detect_distro
    echo "[INFO]   Distribution détectée : $DISTRO"

    if is_rhel_family; then
        command -v update-ca-trust &>/dev/null \
            || { echo "[ERREUR] update-ca-trust introuvable." >&2; exit 1; }
        local dest="/etc/pki/ca-trust/source/anchors/${domain}.crt"
        echo "[INFO]   Copie vers ${dest}..."
        cp "$ca_cert" "$dest"
        chmod 644 "$dest"
        echo "[INFO]   Mise à jour du magasin..."
        update-ca-trust extract
        trust list 2>/dev/null | grep -qi "$domain" \
            && echo "[INFO]   CA trouvée dans le magasin ✔" \
            || echo "[WARN]   Vérifiez manuellement : trust list | grep ${domain}"

    elif is_debian_family; then
        command -v update-ca-certificates &>/dev/null \
            || { echo "[ERREUR] update-ca-certificates introuvable. Installez : apt install ca-certificates" >&2; exit 1; }
        local dest="/usr/local/share/ca-certificates/${domain}.crt"
        echo "[INFO]   Copie vers ${dest}..."
        cp "$ca_cert" "$dest"
        chmod 644 "$dest"
        echo "[INFO]   Mise à jour du magasin..."
        update-ca-certificates

    else
        echo "[ERREUR] Distribution '$DISTRO' non supportée." >&2; exit 1
    fi

    echo ""
    echo "[WARN]   Firefox gère son propre magasin. Pour y ajouter la CA :"
    echo "[WARN]     Paramètres -> Vie privée -> Certificats -> Autorités -> Importer -> ${ca_cert}"
    echo ""
    echo "[INFO]   CA '${domain}' installée avec succès"
}

#  --remove-ca
cmd_remove_ca() {
    echo ""
    echo "=== Suppression d'une CA du magasin système ==="
    echo ""

    [[ $EUID -eq 0 ]] \
        || { echo "[ERREUR] Cette opération nécessite les droits root (sudo $0 --remove-ca)." >&2; exit 1; }

    detect_distro
    load_installed_cas
    [[ ${#INSTALLED_CAS[@]} -gt 0 ]] \
        || { echo "[ERREUR] Aucun certificat trouvé dans le magasin système." >&2; exit 1; }

    select_menu "Quelle CA souhaitez-vous supprimer ?" "${INSTALLED_CAS[@]}"
    local selected="$MENU_RESULT"

    local selected_path=""
    for i in "${!INSTALLED_CAS[@]}"; do
        if [[ "${INSTALLED_CAS[$i]}" == "$selected" ]]; then
            selected_path="${INSTALLED_CAS_PATHS[$i]}"
            break
        fi
    done
    [[ -n "$selected_path" && -f "$selected_path" ]] \
        || { echo "[ERREUR] Fichier introuvable : $selected_path" >&2; exit 1; }

    echo -n "? Supprimer '${selected}' du magasin système ? [o/N] : "
    read -r confirm
    [[ "$confirm" =~ ^[oO]$ ]] || { echo "[INFO]   Annulé."; return 0; }

    echo "[INFO]   Suppression de ${selected_path}..."
    rm -f "$selected_path"

    if is_rhel_family; then
        update-ca-trust extract
    elif is_debian_family; then
        update-ca-certificates --fresh
    fi

    echo "[INFO]   CA '${selected}' supprimée du magasin ✔"
}

#  --new-cert
cmd_new_cert() {
    local -a fqdns=("$@")
    [[ ${#fqdns[@]} -gt 0 ]] \
        || { echo "[ERREUR] Spécifiez au moins un FQDN : $0 --new-cert <fqdn> [fqdn2 ...]" >&2; exit 1; }

    echo ""
    echo "=== Génération d'un nouveau certificat ==="
    echo ""

    load_local_cas
    [[ ${#LOCAL_CAS[@]} -gt 0 ]] \
        || { echo "[ERREUR] Aucune CA locale trouvée. Créez-en une avec : $0 --create-ca" >&2; exit 1; }

    ask_default "Durée de validité (jours)" "3650"
    local cert_days="$REPLY"
    [[ "$cert_days" =~ ^[0-9]+$ && "$cert_days" -gt 0 ]] \
        || { echo "[ERREUR] Durée invalide : $cert_days" >&2; exit 1; }

    ask_default "Taille de la clé RSA (bits)" "4096"
    local key_bits="$REPLY"
    [[ "$key_bits" =~ ^(2048|4096|8192)$ ]] \
        || { echo "[ERREUR] Taille de clé invalide (valeurs acceptées : 2048, 4096, 8192)" >&2; exit 1; }

    # Validation des FQDNs
    local -a valid_fqdns=()
    local fqdn_regex='^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$'
    for fqdn in "${fqdns[@]}"; do
        if [[ "$fqdn" =~ $fqdn_regex ]]; then
            valid_fqdns+=("$fqdn")
            echo "[INFO]   FQDN accepté : $fqdn"
        else
            echo "[WARN]   FQDN ignoré (format invalide) : $fqdn"
        fi
    done
    [[ ${#valid_fqdns[@]} -gt 0 ]] \
        || { echo "[ERREUR] Aucun FQDN valide fourni." >&2; exit 1; }

    local main_fqdn="${valid_fqdns[0]}"

    # Auto-détection de la CA correspondant au domaine du FQDN
    # (correspondance suffixe la plus longue parmi les CAs locales)
    local domain=""
    local -a matches=()
    for ca in "${LOCAL_CAS[@]}"; do
        if [[ "$main_fqdn" == "$ca" || "$main_fqdn" == *".${ca}" ]]; then
            matches+=("$ca")
        fi
    done

    if [[ ${#matches[@]} -gt 0 ]]; then
        # Garde la correspondance la plus spécifique (nom le plus long)
        domain="${matches[0]}"
        for m in "${matches[@]}"; do
            [[ ${#m} -gt ${#domain} ]] && domain="$m"
        done
        # En cas d'égalité entre plusieurs matches de même longueur -> ambiguïté, on redemande
        local -a same_length=()
        for m in "${matches[@]}"; do
            [[ ${#m} -eq ${#domain} ]] && same_length+=("$m")
        done
        if [[ ${#same_length[@]} -gt 1 ]]; then
            echo "[WARN]   Plusieurs CAs correspondent au domaine de '${main_fqdn}'."
            select_menu "Quelle CA doit signer ce certificat ?" "${same_length[@]}"
            domain="$MENU_RESULT"
        else
            echo "[INFO]   CA détectée automatiquement pour '${main_fqdn}' : ${domain}"
        fi
    elif [[ ${#LOCAL_CAS[@]} -eq 1 ]]; then
        domain="${LOCAL_CAS[0]}"
        echo "[INFO]   Aucune CA ne correspond au domaine de '${main_fqdn}', utilisation de la seule CA disponible : ${domain}"
    else
        echo "[WARN]   Aucune CA locale ne correspond au domaine de '${main_fqdn}'."
        select_menu "Quelle CA doit signer ce certificat ?" "${LOCAL_CAS[@]}"
        domain="$MENU_RESULT"
    fi

    [[ -f "CA/${domain}/${domain}-ca.crt" ]] \
        || { echo "[ERREUR] Certificat CA introuvable : CA/${domain}/${domain}-ca.crt" >&2; exit 1; }
    [[ -f "CA/${domain}/${domain}-ca.key" ]] \
        || { echo "[ERREUR] Clé CA introuvable : CA/${domain}/${domain}-ca.key" >&2; exit 1; }

    local cert_dir="certs/${main_fqdn}"
    local base="${cert_dir}/${main_fqdn}"
    local ca_dir="CA/${domain}"
    local ca_base="${ca_dir}/${domain}-ca"

    if [[ -f "${base}.crt" ]]; then
        echo "[WARN]   Un certificat existe déjà pour '${main_fqdn}'."
        echo -n "? Ecraser ? [o/N] : "
        read -r confirm
        [[ "$confirm" =~ ^[oO]$ ]] || { echo "[INFO]   Annulé."; return 0; }
    fi

    mkdir -p "$cert_dir"

    echo "[INFO]   Création du fichier d'extensions SAN..."
    local san_block=""
    local i=1
    for fqdn in "${valid_fqdns[@]}"; do
        san_block+="DNS.${i} = ${fqdn}"$'\n'
        (( i++ ))
    done

    local org="${domain%%.*}"
    cat > "${base}.ext" << EOF
authorityKeyIdentifier = keyid,issuer
basicConstraints       = CA:FALSE
keyUsage               = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage       = serverAuth, clientAuth
subjectAltName         = @alt_names

[alt_names]
${san_block}
EOF

    echo "[INFO]   Génération de la clé privée (RSA ${key_bits} bits)..."
    openssl genpkey -algorithm RSA \
        -out "${base}.key" \
        -pkeyopt rsa_keygen_bits:"${key_bits}"
    chmod 600 "${base}.key"

    echo "[INFO]   Génération du CSR..."
    openssl req -new \
        -key "${base}.key" \
        -out "${base}.csr" \
        -subj "/C=FR/ST=BOURGOGNE/L=DIJON/O=${org^^}/OU=${org^^}/CN=${main_fqdn}"

    echo "[INFO]   Signature par la CA '${domain}' (${cert_days} jours)..."
    openssl x509 -req \
        -in "${base}.csr" \
        -CA "${ca_base}.crt" \
        -CAkey "${ca_base}.key" \
        -CAcreateserial \
        -out "${base}.crt" \
        -days "${cert_days}" \
        -sha256 \
        -extfile "${base}.ext"
    chmod 644 "${base}.crt"

    echo "[INFO]   Génération du PEM (certificat + clé)..."
    cat "${base}.crt" "${base}.key" > "${base}.pem"
    chmod 600 "${base}.pem"

    echo "[INFO]   Génération du fullchain PEM (certificat + CA)..."
    cat "${base}.crt" "${ca_base}.crt" > "${base}-fullchain.pem"
    chmod 644 "${base}-fullchain.pem"

    rm -f "${base}.csr"

    echo "[INFO]   Vérification..."
    openssl verify -CAfile "${ca_base}.crt" "${base}.crt"
    echo ""
    openssl x509 -in "${base}.crt" -noout -subject -issuer -dates -ext subjectAltName

    echo ""
    echo "[INFO]   Certificat '${main_fqdn}' généré avec succès"
    echo "[INFO]     ${base}.key            -> clé privée  (chmod 600)"
    echo "[INFO]     ${base}.crt            -> certificat"
    echo "[INFO]     ${base}.pem            -> cert + clé  (chmod 600)"
    echo "[INFO]     ${base}-fullchain.pem  -> cert + CA"
}

#  --squid-ca
cmd_squid_ca() {
    echo ""
    echo "=== Génération d'un PEM CA pour Squid (ssl-bump) ==="
    echo ""

    load_local_cas
    [[ ${#LOCAL_CAS[@]} -gt 0 ]] \
        || { echo "[ERREUR] Aucune CA locale trouvée. Créez-en une avec : $0 --create-ca" >&2; exit 1; }

    local domain
    if [[ ${#LOCAL_CAS[@]} -eq 1 ]]; then
        domain="${LOCAL_CAS[0]}"
        echo "[INFO]   CA utilisée : ${domain}"
    else
        select_menu "Quelle CA utiliser pour Squid ?" "${LOCAL_CAS[@]}"
        domain="$MENU_RESULT"
    fi

    local ca_dir="CA/${domain}"
    local ca_base="${ca_dir}/${domain}-ca"
    [[ -f "${ca_base}.crt" && -f "${ca_base}.key" ]] \
        || { echo "[ERREUR] CA introuvable : ${ca_base}.crt / .key" >&2; exit 1; }

    local squid_dir="squid/${domain}"
    mkdir -p "$squid_dir"
    chmod 700 "$squid_dir"
    local squid_key="${squid_dir}/${domain}-squid-ca.key"
    local squid_pem="${squid_dir}/${domain}-squid-ca.pem"

    if [[ -f "${squid_pem}" ]]; then
        echo "[WARN]   Un PEM Squid existe déjà pour '${domain}'."
        echo -n "? Ecraser ? [o/N] : "
        read -r confirm
        [[ "$confirm" =~ ^[oO]$ ]] || { echo "[INFO]   Annulé."; return 0; }
    fi

    echo "[INFO]   Déchiffrement de la clé CA (saisissez la passphrase de la CA)..."
    openssl rsa -in "${ca_base}.key" -out "${squid_key}"
    chmod 600 "${squid_key}"

    echo "[INFO]   Génération du PEM combiné (clé en clair + certificat CA)..."
    cat "${squid_key}" "${ca_base}.crt" > "${squid_pem}"
    chmod 600 "${squid_pem}"

    # On ne garde que le PEM final, pas la clé en clair isolée
    rm -f "${squid_key}"

    echo ""
    echo "[INFO]   Fichier Squid généré : ${squid_pem}"
    echo "[INFO]   Vérification..."
    openssl x509 -in "${squid_pem}" -noout -subject -issuer -dates
    if openssl rsa -in "${squid_pem}" -noout -check 2>/dev/null; then
        echo "[INFO]   Clé privée OK (non chiffrée)"
    else
        echo "[ERREUR] La clé privée du PEM Squid semble invalide." >&2
        exit 1
    fi

    echo ""
    echo "[WARN]   Ce fichier contient une clé privée EN CLAIR."
    echo "[WARN]     Protégez-le : chmod 600, propriétaire root (ou l'utilisateur squid), hors dépôt git."
    echo "[WARN]   Distribuez ${ca_base}.crt (PAS ce PEM) aux clients/postes pour qu'ils fassent confiance à Squid."
    echo ""
    echo "[INFO]   Config Squid (squid.conf) :"
    echo "[INFO]     http_port 3129 ssl-bump \\"
    echo "[INFO]       cert=$(pwd)/${squid_pem} \\"
    echo "[INFO]       generate-host-certificates=on dynamic_cert_mem_cache_size=4MB"
    echo "[INFO]     acl step1 at_step SslBump1"
    echo "[INFO]     ssl_bump peek step1"
    echo "[INFO]     ssl_bump bump all"
    echo "[INFO]     sslcrtd_program /usr/lib/squid/security_file_certgen -s /var/lib/squid/ssl_db -M 4MB"
    echo ""
    echo "[INFO]   Pensez à initialiser la base sslcrtd si ce n'est pas déjà fait :"
    echo "[INFO]     /usr/lib/squid/security_file_certgen -c -s /var/lib/squid/ssl_db -M 4MB"
    echo "[INFO]     chown -R squid:squid /var/lib/squid/ssl_db"
}

#  Aide
usage() {
    echo ""
    echo "simpleca.sh - Gestion PKI interne"
    echo ""
    echo "Usage :"
    echo "  ./simpleca.sh --create-ca                     Creer une nouvelle CA"
    echo "  ./simpleca.sh --new-cert <fqdn> [fqdn2 ...]   Generer un certificat serveur"
    echo "  ./simpleca.sh --install-ca                    Installer la CA dans le systeme"
    echo "  ./simpleca.sh --remove-ca                     Supprimer la CA du systeme"
    echo "  ./simpleca.sh --squid-ca                      Generer un PEM CA pour Squid (ssl-bump)"
    echo "  ./simpleca.sh -h, --help                      Afficher cette aide"
    echo ""
    echo "Exemples :"
    echo "  ./simpleca.sh --create-ca"
    echo "  ./simpleca.sh --new-cert srv01.linuxtricks.lan"
    echo "  ./simpleca.sh --new-cert srv01.linuxtricks.lan www.linuxtricks.lan"
    echo "  sudo ./simpleca.sh --install-ca"
    echo "  sudo ./simpleca.sh --remove-ca"
    echo "  ./simpleca.sh --squid-ca"
    echo ""
    exit 0
}

#  Début Script
command -v openssl &>/dev/null \
    || { echo "[ERREUR] openssl n'est pas installé." >&2; exit 1; }
[[ $# -lt 1 ]] && usage

case "$1" in
    --create-ca)  cmd_create_ca ;;
    --install-ca) cmd_install_ca ;;
    --remove-ca)  cmd_remove_ca ;;
    --new-cert)   shift; cmd_new_cert "$@" ;;
    --squid-ca)   cmd_squid_ca ;;
    -h|--help)    usage ;;
    *)            echo "[ERREUR] Option inconnue : '$1'  (--help pour l'aide)" >&2; exit 1 ;;
esac
