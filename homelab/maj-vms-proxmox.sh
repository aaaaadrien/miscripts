#!/usr/bin/env bash

## TODO
# - Gérer quand le premier reboot n'est pas OK (genre pas de tools)
# - Gérer si quand pas de tools, tester le ssh avec le nom de la machine (sinon éteindre)
# - Gerer quand pas la clé SSH
# - Arch : gestion AUR
# - NixOS : a intégrer
# - Gestion par TAG
# Liste des VMS
# pvesh get /cluster/resources -type vm --output-format yaml | egrep -i 'vmid|name' | sed 's@.*:@@' | paste - - -d ""
# pour recuperer les VMs qui ont in $TAGNAME :
# pvesh get /cluster/resources --type vm --output-format json | jq -r '.[] | select(.tags != null and (.tags | split(";") | contains(["$TAGNAME"]))) | .vmid'
# exemple
#pvesh get /cluster/resources --type vm --output-format json | jq -r '.[] | select(.tags != null and (.tags | split(";") | contains(["0-distrotests"]))) | .vmid'
## END TODO

# Gestion des erreurs propre
set -euo pipefail

# Config
PVE_HOSTS=("pve241" "pve243")         # tableau de PVE hosts (modifiable via --pve)
VM_IDS=()                    # tableau des VMID à traiter (rempli via --id)
BOOT_TIMEOUT=40              # secondes max pour attendre le démarrage
REBOOT_TIMEOUT=40            # secondes max pour attendre le reboot
SSH_TIMEOUT=10               # timeout connexion SSH (secondes)
SSH_KEY=~/.ssh/id_rsa        # clé privée SSH utilisée pour toutes les connexions
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=${SSH_TIMEOUT} -o BatchMode=yes"
LOG_FILE="${LOG_FILE:-/var/tmp/maj-vms-proxmox.log}"

# Tableaux de résultats
declare -A VM_NAME VM_STATUS VM_ERROR VM_PVE

# Contexte courant
_CURRENT_VMID=""
_CURRENT_PVE=""

# Aide
show_help() {
    cat <<EOF
maj-vms-proxmox.sh : Mise à jour automatique des VMs Proxmox

Usage
  ./maj-vms-proxmox.sh [OPTIONS]

Options
  --pve  HOST[,HOST...]   Hôte(s) Proxmox (défaut : pve241)
                          En cas de liste, chaque VM est cherchée sur tous les
                          hôtes dans l'ordre jusqu'à ce qu'elle soit trouvée.
  --id   SPEC[,SPEC...]   VMs à traiter. SPEC peut être :
                          un identifiant seul  : 601
                          une plage inclusive  : 601-630
                          un mix               : 601,605,610-620,630
  --help                  Affiche cette aide.

Exemples
  ./maj-vms-proxmox.sh --pve pve241 --id 601-630
  ./maj-vms-proxmox.sh --pve pve241,pve242 --id 601,605,610-620
  ./maj-vms-proxmox.sh --id 615

Prérequis
  1. QEMU Guest Agent installé et actif sur chaque VM
       Debian/Ubuntu : apt install qemu-guest-agent
       Fedora/Alma   : dnf install qemu-guest-agent
       Alpine        : apk add qemu-guest-agent
       Arch          : pacman -S qemu-guest-agent
       Gentoo        : emerge app-emulation/qemu-guest-agent
       Activation    : systemctl enable --now qemu-guest-agent

  2. Clé publique SSH déposée dans le compte root de chaque VM
       ssh-copy-id root@vm
       
  3. Clé publique SSH déposée dans le compte root de chaque noeud PVE
       ssh-copy-id root@pve
EOF
    exit 0
}

# Parsing des arguments
parse_ids() {
    # Transforme "601,605,610-620,630" en tableau VM_IDS
    local input="$1"
    local part start end
    VM_IDS=()
    IFS=',' read -ra parts <<< "${input}"
    for part in "${parts[@]}"; do
        part="${part// /}"
        if [[ "${part}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            if (( start > end )); then
                echo "Plage invalide : ${part} (début > fin)" >&2; exit 1
            fi
            for id in $(seq "${start}" "${end}"); do VM_IDS+=("${id}"); done
        elif [[ "${part}" =~ ^[0-9]+$ ]]; then
            VM_IDS+=("${part}")
        else
            echo "Identifiant invalide : '${part}'" >&2; exit 1
        fi
    done
    if (( ${#VM_IDS[@]} == 0 )); then
        echo "Aucun VM ID spécifié." >&2; exit 1
    fi
}

parse_pve_hosts() {
    # Transforme "pve241,pve242" en tableau PVE_HOSTS
    IFS=',' read -ra PVE_HOSTS <<< "$1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)  show_help ;;
        --pve)      parse_pve_hosts "$2"; shift 2 ;;
        --id)       parse_ids "$2"; shift 2 ;;
        *)
            echo "Option inconnue : $1\nLancez $0 --help pour l'aide." >&2
            exit 1
            ;;
    esac
done

# Si --id non fourni, appliquer la valeur par défaut 601-630 (a améliorer)
if (( ${#VM_IDS[@]} == 0 )); then
    parse_ids "601-630"
fi


# Fonctions utilitaires à améliorer
log()  { echo "[INFO] $*"; }
ok()   { echo "[OK]   $*"; }
warn() { echo "[WARN] $*"; }
err()  { echo "[ERR]  $*" >&2; }

log_section() {
    echo ""                      >> "${LOG_FILE}"
    echo ">>> $*"              >> "${LOG_FILE}"
}

# Lance une commande sur le PVE courant (_CURRENT_PVE)
pve_exec() {
    ssh ${SSH_OPTS} "root@${_CURRENT_PVE}" "$@"
}

# Cherche sur quel PVE réside une VM et positionne _CURRENT_PVE
# Retourne 0 si trouvée, 1 sinon
find_pve_for_vm() {
    local vmid="$1"
    local host
    for host in "${PVE_HOSTS[@]}"; do
        if ssh ${SSH_OPTS} "root@${host}" "qm status ${vmid}" &>/dev/null; then
            _CURRENT_PVE="${host}"
            VM_PVE[${vmid}]="${host}"
            return 0
        fi
    done
    return 1
}

# Récupère l'IP d'une VM via qm guest info
get_vm_ip() {
    local vmid="$1"
    pve_exec qm guest cmd "${vmid}" network-get-interfaces 2>/dev/null \
        | grep -oP '"ip-address"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
        | grep -v '^127\.' | head -1 || true
}

# Récupère le nom d'une VM
get_vm_name() {
    local vmid="$1"
    pve_exec qm config "${vmid}" 2>/dev/null \
        | grep -oP '(?<=^name: ).*' || echo "vm-${vmid}"
}

# Retourne le statut d'une VM : running stopped ...
vm_state() {
    pve_exec qm status "$1" 2>/dev/null | grep -oP '(?<=status: )\S+' || echo "unknown"
}

# Démarre une VM et attend qu'elle soit accessible en SSH
start_and_wait_vm() {
    local vmid="$1"
    local elapsed=0

    log "Démarrage de la VM ${vmid}..."
    pve_exec qm start "${vmid}"

    while (( elapsed < BOOT_TIMEOUT )); do
        sleep 5; (( elapsed += 5 ))
        local ip; ip=$(get_vm_ip "${vmid}") || true
        if [[ -n "${ip}" ]] && ssh ${SSH_OPTS} "root@${ip}" true &>/dev/null; then
            ok "VM ${vmid} accessible via SSH (${ip}) après ${elapsed}s"
            return 0
        fi
        log "  ... en attente (${elapsed}/${BOOT_TIMEOUT}s)"
    done

    err "VM ${vmid} : timeout démarrage (${BOOT_TIMEOUT}s)"
    return 1
}

# Attend que la VM soit de nouveau accessible après reboot
# Vérifie : SSH accessible ET uptime < uptime_before (reboot effectif, y a peut être mieux)
wait_after_reboot() {
    local vmid="$1"
    local ip="$2"
    local uptime_before="$3"
    local elapsed=0

    # Laisse le temps à la VM d'initier le reboot
    sleep 10

    while (( elapsed < REBOOT_TIMEOUT )); do
        sleep 5; (( elapsed += 5 ))

        if ! ssh ${SSH_OPTS} "root@${ip}" true &>/dev/null; then
            log "  ... pas encore accessible (${elapsed}/${REBOOT_TIMEOUT}s)"
            continue
        fi

        local uptime_now
        uptime_now=$(ssh ${SSH_OPTS} "root@${ip}" "awk '{print int(\$1)}' /proc/uptime" 2>/dev/null) || {
            log "  ... SSH ok mais uptime illisible, on réessaie (${elapsed}/${REBOOT_TIMEOUT}s)"
            continue
        }

        if (( uptime_now < uptime_before )); then
            ok "VM ${vmid} rebootée - uptime avant: ${uptime_before}s / après: ${uptime_now}s (${elapsed}s écoulés)"
            return 0
        else
            log "  ... SSH ok mais uptime ${uptime_now}s >= ${uptime_before}s - reboot pas encore effectif (${elapsed}/${REBOOT_TIMEOUT}s)"
        fi
    done

    err "VM ${vmid} : timeout après reboot (${REBOOT_TIMEOUT}s)"
    return 1
}

# Détection du système
detect_os() {
    local vmid="$1"
    local ip="$2"

    local os_release
    os_release=$(ssh ${SSH_OPTS} "root@${ip}" \
        'cat /etc/os-release 2>/dev/null || cat /usr/lib/os-release 2>/dev/null || echo "ID=unknown"')

    local id; id=$(echo "${os_release}" | grep -oP '(?<=^ID=)[^\n]+' | tr -d '"' | tr -d "'" | head -1 | tr '[:upper:]' '[:lower:]')
    local id_like; id_like=$(echo "${os_release}" | grep -oP '(?<=^ID_LIKE=)[^\n]+' | tr -d '"' | head -1 | tr '[:upper:]' '[:lower:]')
    local variant_id; variant_id=$(echo "${os_release}" | grep -oP '(?<=^VARIANT_ID=)[^\n]+' | tr -d '"' | head -1 | tr '[:upper:]' '[:lower:]')

    case "${id}" in
        debian|ubuntu|linuxmint|pop)                        echo "debian_family"  ;;
        fedora)
            case "${variant_id}" in
                silverblue|kinoite|sericea|onyx|lazurite)   echo "fedora_atomic"  ;;
                *)                                          echo "fedora_family"  ;;
            esac
            ;;
        almalinux|rocky|rhel|centos)                        echo "fedora_family"  ;;
        bazzite|bluefin|aurora)                             echo "ublue"          ;;
        calculate)                                          echo "calculate"      ;;
        alpine)                                             echo "alpine"         ;;
        gentoo)                                             echo "gentoo"         ;;
        arch|manjaro|endeavouros|cachyos|garuda|artix)      echo "arch_family"    ;;
        mageia)                                             echo "mageia"         ;;
        opensuse-*)                                         echo "opensuse"       ;;
        solus)                                              echo "solus"       ;;
        freebsd)                                            echo "freebsd"        ;;
        *)
            case "${id_like}" in
                *debian*|*ubuntu*)  echo "debian_family" ;;
                *fedora*|*rhel*)    echo "fedora_family" ;;
                *calculate*)        echo "calculate"     ;;
                *arch*)             echo "arch_family"   ;;
                *)                  echo "unknown:${id}" ;;
            esac
            ;;
    esac
}


# Fonctions de mise à jour par famille
## DEB
update_debian_family() {
    local ip="$1"
    log "  -- Mise à jour Debian/Ubuntu"
    log_section "VM ${_CURRENT_VMID:-?} Debian/Ubuntu ${ip}"
    ssh ${SSH_OPTS} "root@${ip}" bash -s >> "${LOG_FILE}" 2>&1 <<'ENDSSH'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get full-upgrade -y -q
apt-get clean -y
if command -v snap &>/dev/null; then
    snap refresh || true
fi
if command -v flatpak &>/dev/null; then
    flatpak update --noninteractive -y || true
fi
fstrim -av || true
ENDSSH
}

## Fedora / Red Hat
update_fedora_family() {
    local ip="$1"
    log "  -- Mise à jour Fedora/Red Hat"
    log_section "VM ${_CURRENT_VMID:-?} Fedora/Red Hat ${ip}"
    ssh ${SSH_OPTS} "root@${ip}" bash -s >> "${LOG_FILE}" 2>&1 <<'ENDSSH'
set -e
dnf upgrade -y --refresh
dnf clean all
if command -v flatpak &>/dev/null; then
    flatpak update --noninteractive -y || true
fi
fstrim -av || true
ENDSSH
}

## Fedora Atomique
update_fedora_atomic() {
    local ip="$1"
    log "  -- Mise à jour Fedora Atomic (Silverblue/Kinoite)"
    log_section "VM ${_CURRENT_VMID:-?} Fedora Atomic ${ip}"
    ssh ${SSH_OPTS} "root@${ip}" bash -s >> "${LOG_FILE}" 2>&1 <<'ENDSSH'
set -e
rpm-ostree upgrade
flatpak update --noninteractive -y || true
fstrim -av || true
ENDSSH
}

## Projets Ublue genre bazzite
update_ublue() {
    local ip="$1"
    log "  -- Mise à jour uBlue (Bazzite/Bluefin/Aurora)"
    log_section "VM ${_CURRENT_VMID:-?} uBlue ${ip}"
    ssh ${SSH_OPTS} "root@${ip}" bash -s >> "${LOG_FILE}" 2>&1 <<'ENDSSH'
set -e
rpm-ostree upgrade
flatpak update --noninteractive -y || true
if command -v brew &>/dev/null; then
    brew update && brew upgrade || true
fi
fstrim -av || true
ENDSSH
}

## Calculate
update_calculate() {
    local ip="$1"
    log "  -- Mise à jour Calculate Linux"
    log_section "VM ${_CURRENT_VMID:-?} Calculate ${ip}"
    ssh ${SSH_OPTS} "root@${ip}" bash -s >> "${LOG_FILE}" 2>&1 <<'ENDSSH'
set -e
cl-update -fo
eclean-pkg -d
eclean-dist -d
fstrim -av || true
ENDSSH
}

## Alpine Linux
update_alpine() {
    local ip="$1"
    log "  -- Mise à jour Alpine Linux"
    log_section "VM ${_CURRENT_VMID:-?} Alpine ${ip}"
    ssh ${SSH_OPTS} "root@${ip}" ash -s >> "${LOG_FILE}" 2>&1 <<'ENDSSH'
set -e
apk update
apk upgrade
apk cache clean
if command -v flatpak >/dev/null 2>&1; then
    flatpak update --noninteractive -y || true
fi
fstrim -av || true
ENDSSH
}

## gentoo
update_gentoo() {
    local ip="$1"
    log "  -- Mise à jour Gentoo"
    log_section "VM ${_CURRENT_VMID:-?} Gentoo ${ip}"
    ssh ${SSH_OPTS} "root@${ip}" bash -s >> "${LOG_FILE}" 2>&1 <<'ENDSSH'
set -e
emerge --sync
emerge -1 portage
emerge -gvuDN --with-bdeps=y @world
emerge -c
emerge @preserved-rebuild
emerge @module-rebuild
revdep-rebuild -iq
eclean-pkg -d
eclean-dist -d
fstrim -av || true
ENDSSH
}

## Arch Linux et compagnie
update_arch_family() {
    local ip="$1"
    log "  -- Mise à jour Arch/Manjaro"
    log_section "VM ${_CURRENT_VMID:-?} Arch ${ip}"
    ssh ${SSH_OPTS} "root@${ip}" bash -s >> "${LOG_FILE}" 2>&1 <<'ENDSSH'
set -e
pacman -Syu --noconfirm
orphans=$(pacman -Qqdt 2>/dev/null) || true
if [ -n "${orphans}" ]; then
    echo "${orphans}" | pacman -Rns --noconfirm - || true
fi
pacman -Sc --noconfirm
if command -v flatpak &>/dev/null; then
    flatpak update --noninteractive -y || true
fi
fstrim -av || true
ENDSSH
}

## Mageia (les urpmi)
update_mageia() {
    local ip="$1"
    log "  -- Mise à jour Mageia"
    log_section "VM ${_CURRENT_VMID:-?} Mageia ${ip}"
    ssh ${SSH_OPTS} "root@${ip}" bash -s >> "${LOG_FILE}" 2>&1 <<'ENDSSH'
set -e
urpmi.update -a
urpmi --auto-update --auto
urpme --auto-orphans --auto || true
if command -v flatpak &>/dev/null; then
    flatpak update --noninteractive -y || true
fi
fstrim -av || true
ENDSSH
}

## Opensuse (leap et tumbleweed)
update_opensuse() {
    local ip="$1"
    log "  -- Mise à jour OpenSuse"
    log_section "VM ${_CURRENT_VMID:-?} OpenSuse ${ip}"
    ssh ${SSH_OPTS} "root@${ip}" bash -s >> "${LOG_FILE}" 2>&1 <<'ENDSSH'
set -e
zypper dup -y
if command -v flatpak &>/dev/null; then
    flatpak update --noninteractive -y || true
fi
fstrim -av || true
ENDSSH
}

update_solus() {
    local ip="$1"
    log "  -- Mise à jour Solus"
    log_section "VM ${_CURRENT_VMID:-?} Solus ${ip}"
    ssh ${SSH_OPTS} "root@${ip}" bash -s >> "${LOG_FILE}" 2>&1 <<'ENDSSH'
set -e
eopkg update-repo
eopkg upgrade -y
eopkg delete-cache -y
if command -v flatpak &>/dev/null; then
    flatpak update --noninteractive -y || true
fi
fstrim -av || true
ENDSSH
}

## Inconnu = erreur
update_unknown() {
    local ip="$1"
    local os_id="$2"
    warn "  OS inconnu (${os_id}) : aucune mise à jour effectuée"
    return 1
}

## FreeBSD à faire
update_freebsd() {
    warn "  FreeBSD détecté mais non supporté : aucune mise à jour effectuée"
    return 1
}


# Traitement d'une VM
process_vm() {
    local vmid="$1"
    _CURRENT_VMID="${vmid}"
    local errors=0
    local was_stopped=false

    log "VM ${vmid}"

    # Recherche du PVE hébergeant cette VM
    if ! find_pve_for_vm "${vmid}"; then
        log "VM ${vmid} introuvable sur : ${PVE_HOSTS[*]}"
        VM_STATUS[${vmid}]="SKIP (introuvable)"
        return 0
    fi
    log "Hébergée sur : ${_CURRENT_PVE}"

    VM_NAME[${vmid}]=$(get_vm_name "${vmid}")
    log "Nom : ${VM_NAME[${vmid}]}"

    # Démarrage si nécessaire
    local state; state=$(vm_state "${vmid}")
    if [[ "${state}" == "stopped" ]]; then
        was_stopped=true
        if ! start_and_wait_vm "${vmid}"; then
            VM_STATUS[${vmid}]="ERREUR (démarrage échoué)"
            VM_ERROR[${vmid}]="Impossible de démarrer la VM"
            return 1
        fi
    elif [[ "${state}" != "running" ]]; then
        warn "VM ${vmid} dans un état inattendu : ${state}, ignorée."
        VM_STATUS[${vmid}]="SKIP (état: ${state})"
        return 0
    else
        log "VM ${vmid} déjà en cours d'exécution."
    fi

    # Récupération IP
    local ip; ip=$(get_vm_ip "${vmid}") || true
    if [[ -z "${ip}" ]]; then
        err "VM ${vmid} : impossible de récupérer l'IP"
        VM_STATUS[${vmid}]="ERREUR (IP introuvable)"
        VM_ERROR[${vmid}]="IP introuvable"
        (( errors++ )) || true
    fi

    # Détection OS
    local os_family
    os_family=$(detect_os "${vmid}" "${ip}") || { os_family="unknown"; (( errors++ )) || true; }
    log "OS détecté : ${os_family}"

    # Mise à jour
    local update_rc=0
    case "${os_family}" in
        debian_family)  update_debian_family "${ip}"          || update_rc=$? ;;
        fedora_family)  update_fedora_family "${ip}"          || update_rc=$? ;;
        fedora_atomic)  update_fedora_atomic "${ip}"          || update_rc=$? ;;
        ublue)          update_ublue "${ip}"                  || update_rc=$? ;;
        calculate)      update_calculate "${ip}"              || update_rc=$? ;;
        alpine)         update_alpine "${ip}"                 || update_rc=$? ;;
        gentoo)         update_gentoo "${ip}"                 || update_rc=$? ;;
        arch_family)    update_arch_family "${ip}"            || update_rc=$? ;;
        mageia)         update_mageia "${ip}"                 || update_rc=$? ;;
        opensuse)       update_opensuse "${ip}"               || update_rc=$? ;;
        solus)          update_solus "${ip}"                  || update_rc=$? ;;
        freebsd)        update_freebsd                        || update_rc=$? ;;
        unknown:*)      update_unknown "${ip}" "${os_family}" || update_rc=$? ;;
    esac

    if (( update_rc != 0 )); then
        err "VM ${vmid} : mise à jour terminée avec erreur (rc=${update_rc})"
        VM_ERROR[${vmid}]="${VM_ERROR[${vmid}]:-}; Update rc=${update_rc}"
        (( errors++ )) || true
    else
        ok "Mise à jour terminée."
    fi
    sleep 5

    # Reboot
    if [[ "${os_family}" == unknown:* || "${os_family}" == "freebsd" ]]; then
        warn "OS non supporté (${os_family}) - pas de reboot, extinction directe de la VM ${vmid}"
    else
        local uptime_before=0
        uptime_before=$(ssh ${SSH_OPTS} "root@${ip}" \
            "awk '{print int(\$1)}' /proc/uptime" 2>/dev/null) || uptime_before=0
        log "Uptime avant reboot : ${uptime_before}s"

        log "Reboot de la VM ${vmid}..."
        ssh ${SSH_OPTS} "root@${ip}" "nohup reboot &>/dev/null &" || true

        if ! wait_after_reboot "${vmid}" "${ip}" "${uptime_before}"; then
            VM_STATUS[${vmid}]="ERREUR (timeout post-reboot)"
            VM_ERROR[${vmid}]="${VM_ERROR[${vmid}]:-}; Timeout reboot"
            (( errors++ )) || true
        fi
    fi

    # Extinction si la VM était arrêtée à l'origine ou OS non supporté
    local do_shutdown=false
    $was_stopped                                                       && do_shutdown=true
    [[ "${os_family}" == unknown:* || "${os_family}" == "freebsd" ]]   && do_shutdown=true

    if $do_shutdown; then
        local reason="était arrêtée à l'origine"
        [[ "${os_family}" == unknown:* || "${os_family}" == "freebsd" ]] && reason="OS non supporté (${os_family})"
        log "Extinction de la VM ${vmid} (${reason})..."
        sleep 5
        pve_exec qm shutdown "${vmid}" --timeout 60 || {
            warn "Shutdown propre échoué, arrêt forcé..."
            pve_exec qm stop "${vmid}" || true
        }
        ok "VM ${vmid} éteinte."
    fi

    # Résultat final
    if (( errors == 0 )); then
        VM_STATUS[${vmid}]="OK"
    else
        VM_STATUS[${vmid}]="${VM_STATUS[${vmid}]:-ERREUR (${errors} erreur(s))}"
    fi

    return $(( errors > 0 ? 1 : 0 ))
}


# Programme principal
main() {
    local pve_list; pve_list=$(IFS=','; echo "${PVE_HOSTS[*]}")
    local id_list;  id_list=$(IFS=','; echo "${VM_IDS[*]}")

    echo "Mise à jour automatique de VMs Proxmox"
    echo "  PVE  : ${pve_list}"
    echo "  VMs  : ${id_list} (${#VM_IDS[@]} VM(s))"
    echo ""

    # Initialisation du fichier de log
    {
        echo "  Mise à jour VMs Proxmox"
        echo "  PVE  : ${pve_list}"
        echo "  VMs  : ${id_list}"
    } >> "${LOG_FILE}"
    log "Logs des commandes : ${LOG_FILE}"

    # Vérifie la connexion à chaque PVE host
    local host
    for host in "${PVE_HOSTS[@]}"; do
        if ! ssh ${SSH_OPTS} "root@${host}" true &>/dev/null; then
            err "Impossible de se connecter à ${host} en SSH. Abandon."
            exit 2
        fi
        ok "Connexion SSH à ${host} établie."
    done
    echo

    local global_rc=0

    for vmid in "${VM_IDS[@]}"; do
        process_vm "${vmid}" || { global_rc=1; }
        echo
    done

    return "${global_rc}"
}

main
