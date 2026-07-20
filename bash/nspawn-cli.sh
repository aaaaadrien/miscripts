#!/usr/bin/env bash
#
# nspawn-ctl.sh - Gestion simple de conteneurs systemd-nspawn
#
# Distributions supportees : almalinux, alpine, archlinux, centos, debian, fedora, ubuntu
# Source des images : https://images.linuxcontainers.org/images/
#
set -u

BASE_URL="https://images.linuxcontainers.org/images"
DISTROS=(almalinux alpine archlinux centos debian fedora ubuntu)

usage() {
    cat <<EOF
Usage: $0 <commande> [arguments]

Commandes disponibles :

  list
      Liste les distributions, versions et architectures disponibles.

  download <distro> <version> <arch> <nom_dossier> [variant]
      Telecharge et decompresse un conteneur dans le repertoire courant,
      dans le dossier <nom_dossier>. Le variant vaut "default" si omis.

  bash <nom_dossier>
      Demarre le conteneur en mode utilisateur root pour initialiser
      le mot de passe (equivalent a --user=root).

  start <nom_dossier>
      Demarre le conteneur en mode boot (equivalent a --boot).

Exemples :
  $0 list
  $0 list almalinux
  $0 download almalinux 10 x86_64 monconteneur
  $0 bash monconteneur
  $0 start monconteneur
EOF
}

# Recupere les noms de dossiers (href se terminant par /) sur une page d'index
list_dirs() {
    local url="$1"
    curl -s "$url" | grep -oP 'href="\K[^"?]+(?=/")' | grep -v '^\.\.$'
}

cmd_list() {
    local distro="${1:-}"

    if [ -z "$distro" ]; then
        echo "Distributions disponibles :"
        for d in "${DISTROS[@]}"; do
            echo "  ${d}"
        done
        echo
        echo "Pour le detail d'une distribution : $0 list <distro>"
        return
    fi

    local found=0
    for d in "${DISTROS[@]}"; do
        [ "$d" = "$distro" ] && found=1
    done
    if [ "$found" -eq 0 ]; then
        echo "Erreur : distribution '${distro}' non supportee."
        echo "Distributions disponibles : ${DISTROS[*]}"
        exit 1
    fi

    echo "=== ${distro} ==="
    local versions
    versions=$(list_dirs "${BASE_URL}/${distro}/")
    if [ -z "$versions" ]; then
        echo "  (aucune version trouvee)"
        return
    fi
    for version in $versions; do
        local archs
        archs=$(list_dirs "${BASE_URL}/${distro}/${version}/")
        for arch in $archs; do
            echo "  ${version} / ${arch}"
        done
    done
}

cmd_download() {
    local distro="${1:-}"
    local version="${2:-}"
    local arch="${3:-}"
    local name="${4:-}"
    local variant="${5:-default}"

    if [ -z "$distro" ] || [ -z "$version" ] || [ -z "$arch" ] || [ -z "$name" ]; then
        echo "Usage: $0 download <distro> <version> <arch> <nom_dossier> [variant]"
        exit 1
    fi

    if [ -e "$name" ]; then
        echo "Erreur : le dossier '${name}' existe deja."
        exit 1
    fi

    local variant_url="${BASE_URL}/${distro}/${version}/${arch}/${variant}"
    local last_date
    last_date=$(list_dirs "${variant_url}/" | sort | tail -n1)

    if [ -z "$last_date" ]; then
        echo "Erreur : aucune image trouvee sur ${variant_url}/"
        exit 1
    fi

    local rootfs_url="${variant_url}/${last_date}/rootfs.tar.xz"
    echo "Telechargement de : ${rootfs_url}"

    local tmpfile
    tmpfile=$(mktemp)

    if ! curl -s -f -L -o "$tmpfile" "$rootfs_url"; then
        echo "Erreur lors du telechargement de ${rootfs_url}"
        rm -f "$tmpfile"
        exit 1
    fi

    mkdir -p "$name"
    echo "Decompression dans ./${name}"
    tar -xf "$tmpfile" -C "$name"
    rm -f "$tmpfile"

    echo "Conteneur pret dans ./${name}"
}

cmd_bash() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: $0 init <nom_dossier>"
        exit 1
    fi
    if [ ! -d "$name" ]; then
        echo "Erreur : le dossier '${name}' n'existe pas."
        exit 1
    fi
    sudo systemd-nspawn --hostname="${name}" --directory="$(pwd)/${name}" --user=root
}

cmd_start() {
    local name="${1:-}"
    if [ -z "$name" ]; then
        echo "Usage: $0 start <nom_dossier>"
        exit 1
    fi
    if [ ! -d "$name" ]; then
        echo "Erreur : le dossier '${name}' n'existe pas."
        exit 1
    fi
    sudo systemd-nspawn --hostname="${name}" --directory="$(pwd)/${name}" --boot
}

main() {
    local command="${1:-}"
    [ $# -gt 0 ] && shift

    case "$command" in
        list)
            cmd_list "$@"
            ;;
        download)
            cmd_download "$@"
            ;;
        bash)
            cmd_bash "$@"
            ;;
        start)
            cmd_start "$@"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
