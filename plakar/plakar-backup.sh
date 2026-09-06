#!/bin/bash

usage() {
    cat <<EOF
Usage: $(basename "$0") [-d DEST] [-r [cli|gui]] [-l] [-h]

  -d DEST      Destination : LOCAL1 / LOCAL2 / NFS / SSH (sinon demandé)
  -r [MODE]    Restauration : cli (défaut) ou gui
  -l           Lister les backups d'un repo (HOME/DATA)
  -h, --help   Affiche cette aide

Sans option : lance la sauvegarde + prune + ls + maintenance.
EOF
}

for arg in "$@"; do
    [[ "$arg" == "-h" || "$arg" == "--help" ]] && { usage; exit 0; }
done

# Chargement de la conf
CONF_FILE="$(dirname "$0")/plakar-backup.conf"
[[ -f "$CONF_FILE" ]] || { echo "Fichier de conf introuvable : $CONF_FILE"; exit 1; }
source "$CONF_FILE"

# Option -d pour passer la destination en argument
# Option -r pour lancer une restauration (cli|gui, cli par défaut)
while getopts "d:rl" opt; do
    case $opt in
        d) DEST="$OPTARG" ;;
        r) RESTORE=1 ;;
        l) LIST=1 ;;
    esac
done
shift $((OPTIND-1))

# Choix destination
# TODO Lister les emplacements
if [[ -z "$DEST" ]]; then
    read -p "Destination ? (LOCAL1/LOCAL2/NFS/SSH) " DEST
fi

case "$DEST" in
    LOCAL1)
        pathsav="$LOCAL1_PATH"
        ;;
    LOCAL2)
        pathsav="$LOCAL2_PATH"
        ;;
    NFS)
        pathsav="$NFS_MOUNT_POINT"
        mount -t nfs4 "$NFS_MOUNT_SRC" "$NFS_MOUNT_POINT"
        [[ $? -ne 0 ]] && { echo "Echec montage NFS, abandon"; exit 1; }
        echo "Montage NFS ok"
        ;;
    SSH)
        pathsav="$SSH_MOUNT_POINT"
        sshfs $SSH_OPTIONS "$SSH_MOUNT_SRC" "$SSH_MOUNT_POINT"
        [[ $? -ne 0 ]] && { echo "Echec montage SSH, abandon"; exit 1; }
        echo "Montage SSH ok"
        ;;
    *)
        echo "Destination inconnue : $DEST"
        exit 1
        ;;
esac

# Vérification que la destination est bien un point de montage actif (et pas /)
check_mountpoint() {
    local path="$1"

    if [[ "$(readlink -f "$path")" == "/" ]]; then
        echo "ERREUR : la destination résolue est '/', abandon."
        exit 1
    fi

    if ! mountpoint -q "$path"; then
        echo "ERREUR : $path n'est pas un point de montage actif, abandon."
        [[ "$DEST" == "NFS" ]] && umount "$NFS_MOUNT_POINT" 2>/dev/null
        [[ "$DEST" == "SSH" ]] && fusermount -u "$SSH_MOUNT_POINT" 2>/dev/null
        exit 1
    fi
}

check_mountpoint "$pathsav"

# Démontage selon destination
unmount_dest() {
    [[ "$DEST" == "NFS" ]] && umount "$NFS_MOUNT_POINT"
    [[ "$DEST" == "SSH" ]] && fusermount -u "$SSH_MOUNT_POINT"
}

# Mode Listing
if [[ "$LIST" == "1" ]]; then
    read -p "Quel repo lister (HOME/DATA) ? " REPO
    echo "### LISTING $REPO ###"
    plakar at "$pathsav/plakar-$REPO" ls
    unmount_dest
    exit 0
fi

# Mode Restauration
if [[ "$RESTORE" == "1" ]]; then
    RESTORE_MODE="${1:-cli}"
    read -p "Quel repo restaurer (HOME/DATA) ? " REPO

    case "$RESTORE_MODE" in
        gui)
            echo "### RESTAURATION (GUI) $REPO ###"
            plakar at "$pathsav/plakar-$REPO" ui
            ;;
        cli)
            echo "### RESTAURATION (CLI) $REPO ###"
            mkdir -p "$RESTORE_PATH"
            echo "Montage du backup sur $RESTORE_PATH"
            plakar at "$pathsav/plakar-$REPO" mount -to "$RESTORE_PATH"
            ;;
        *)
            echo "Mode de restauration inconnu : $RESTORE_MODE (attendu: cli ou gui)"
            unmount_dest
            exit 1
            ;;
    esac

    unmount_dest
    exit 0
fi

# Vérification destination
echo "========================================"
df -h "$pathsav"
echo "========================================"
read -t 10 -p "Destination ($pathsav) OK ? (Entrée ou attente 10s = continuer, Ctrl+C pour annuler dans les 10 secondes)"
echo ""

# Sauvegardes
for i in 1 2 3 4 5; do
    eval "src_path=\$SOURCE${i}_PATH"
    eval "src_repo=\$SOURCE${i}_REPO"
    [[ -z "$src_path" ]] && continue

    echo "### BACKUP $src_repo ###"
    plakar at "$pathsav/plakar-$src_repo" backup -ignore-file "$EXCLUDE_FILE" "$src_path"
    if [[ $? -eq 0 ]]; then
        echo "Epuration des anciens backups $src_repo"
        plakar at "$pathsav/plakar-$src_repo" prune $PRUNE_OPTS -apply
    fi
done

echo "--------------------------------"

# Listing & maintenance
for i in 1 2 3 4 5; do
    eval "src_path=\$SOURCE${i}_PATH"
    eval "src_repo=\$SOURCE${i}_REPO"
    [[ -z "$src_path" ]] && continue

    echo "Sauvegardes $src_repo"
    plakar at "$pathsav/plakar-$src_repo" ls
    sleep 1

    echo "Ménage $src_repo"
    plakar at "$pathsav/plakar-$src_repo" maintenance
    sleep 1
done

unmount_dest
