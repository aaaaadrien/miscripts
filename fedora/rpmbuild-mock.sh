#!/bin/bash

# Valeurs par défaut récupérées depuis le système
DEFAULT_DIST=$(grep --color=none -Po '^ID=\K.*' /etc/os-release | tr -d '"')
DEFAULT_REL=$(grep --color=none -Po '^VERSION_ID="?\K[^."]*' /etc/os-release)
DEFAULT_ARCH=$(uname -m)

DIST="$DEFAULT_DIST"
REL="$DEFAULT_REL"
ARCH="$DEFAULT_ARCH"
COPRS=()

usage() {
    echo "Usage: $0 [OPTIONS] <fichier.spec>"
    echo ""
    echo "Options:"
    echo "  -d DIST         Distribution (défaut: $DEFAULT_DIST)"
    echo "  -r REL          Version de la distribution (défaut: $DEFAULT_REL)"
    echo "  -a ARCH         Architecture (défaut: $DEFAULT_ARCH)"
    echo "  -c USER/PROJET  Dépôt COPR à activer (répétable)"
    echo "  -h              Afficher cette aide"
    echo ""
    echo "Exemples:"
    echo "  $0 -c adriend/fedora-apps monpaquet.spec"
    echo "  $0 -d rhel -r 10 monpaquet.spec"
    exit 1
}

while getopts "d:r:a:c:h" opt; do
    case "$opt" in
        d) DIST="$OPTARG" ;;
        r) REL="$OPTARG" ;;
        a) ARCH="$OPTARG" ;;
        c) COPRS+=("$OPTARG") ;;
        h) usage ;;
        *) usage ;;
    esac
done

shift $((OPTIND - 1))

SPEC_FILE="$1"

if [[ -z "$SPEC_FILE" ]]; then
    echo "Erreur : fichier .spec manquant." >&2
    usage
fi

if [[ ! -f "$SPEC_FILE" ]]; then
    echo "Erreur : le fichier '$SPEC_FILE' n'existe pas." >&2
    exit 1
fi

MOCK_ROOT="${DIST}-${REL}-${ARCH}"
RPMBUILD_DIR="$HOME/rpmbuild"
OUTPUT_DIR="$RPMBUILD_DIR/MOCK"

echo "==> Configuration Mock"
echo "    Racine  : $MOCK_ROOT"
echo "    Spec    : $SPEC_FILE"
echo "    Sortie  : $OUTPUT_DIR"

read -t 10 

# Construction des arguments COPR
COPR_ARGS=()
for copr in "${COPRS[@]}"; do
    COPR_URL="https://copr.fedorainfracloud.org/coprs/${copr}/repo/${DIST}-${REL}/"
    echo "    COPR    : $copr ($COPR_URL)"
    COPR_ARGS+=("--addrepo" "$COPR_URL")
done
echo ""

# Création des dossiers si non existants
mkdir -p \
    "$OUTPUT_DIR" \
    "$RPMBUILD_DIR/SOURCES" \
    "$RPMBUILD_DIR/$DIST" \
    "$RPMBUILD_DIR/$DIST/SRPMS" \
    "$RPMBUILD_DIR/$DIST/RPMS" \
    "$RPMBUILD_DIR/$DIST/SPECS"

# Suppression anciens logs
find "$OUTPUT_DIR" -name "*.log" -delete

# Lancement du build
mock -r "$MOCK_ROOT" \
     --enable-network \
     --sources="$RPMBUILD_DIR/SOURCES" \
     --spec="$SPEC_FILE" \
     --resultdir="$OUTPUT_DIR" \
     "${COPR_ARGS[@]}" \
     --rebuild

MOCK_EXIT=$?

# On sort si erreur mock
if [[ $MOCK_EXIT -ne 0 ]]; then
    echo "Erreur : mock a échoué avec le code $MOCK_EXIT." >&2
    exit $MOCK_EXIT
fi

# Déplacement des fichiers aux bons endroits
find "$OUTPUT_DIR" -name "*debuginfo*.rpm" -delete
find "$OUTPUT_DIR" -name "*debugsource*.rpm" -delete
find "$OUTPUT_DIR" -name "*.src.rpm" -exec mv -v "{}" "$RPMBUILD_DIR/$DIST/SRPMS/" \;
find "$OUTPUT_DIR" -name "*.rpm" -exec mv -v "{}" "$RPMBUILD_DIR/$DIST/RPMS/" \;

echo ""
echo "==> Build terminé. RPMs disponibles dans : $RPMBUILD_DIR/$DIST"
