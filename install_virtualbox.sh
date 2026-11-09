#!/usr/bin/env bash
# Instala o VirtualBox 7.2 num Ubuntu (máquina própria, com sudo), como foi feito no host dos experimentos:
#   1. repositório da Oracle (o virtualbox do Ubuntu não compila no kernel 6.17) e pacote virtualbox-7.2
#   2. usuário no grupo vboxusers
#   3. KVM sem VMX ao carregar (kernel ≥ 6.12): options kvm enable_virt_at_load=0
#   4. Secure Boot: chave MOK registrada + vboxconfig (módulos do VirtualBox assinados)
#   5. verificação final
# Uso: sudo ./install_virtualbox.sh   (rode de novo depois do reboot de registro da MOK, se pedido)
# No LCC3 não é preciso: o VirtualBox já está instalado.
set -euo pipefail

log() { echo "[$(date '+%F %T')] $*" >&2; }
die() { log "ERRO: $*"; exit 1; }

(( EUID == 0 )) || die "rode com sudo: sudo $0"
USER_NAME="${SUDO_USER:-}"
[[ -n "$USER_NAME" && "$USER_NAME" != root ]] || die "rode com sudo a partir do seu usuário (não como root direto)"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || log "AVISO: testado só em Ubuntu (este é ${PRETTY_NAME:-desconhecido})"
CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
REBOOT=0

# --- 1. repositório da Oracle e pacote ---------------------------------------------
KEYRING=/usr/share/keyrings/oracle-virtualbox-2016.gpg
LIST=/etc/apt/sources.list.d/virtualbox.list
apt-get update -qq
apt-get install -y -qq curl gpg ca-certificates build-essential dkms "linux-headers-$(uname -r)" mokutil \
    rsync bc iproute2 openssh-client git >/dev/null
if [[ ! -s "$KEYRING" ]]; then
    log "Chave do repositório da Oracle → $KEYRING"
    curl -fsSL https://www.virtualbox.org/download/oracle_vbox_2016.asc | gpg --dearmor --yes -o "$KEYRING"
fi
LINE="deb [arch=amd64 signed-by=$KEYRING] https://download.virtualbox.org/virtualbox/debian $CODENAME contrib"
if [[ "$(cat "$LIST" 2>/dev/null)" != "$LINE" ]]; then
    log "Repositório: $LINE"
    echo "$LINE" >"$LIST"
fi
apt-get update -qq
if dpkg -s virtualbox-7.2 >/dev/null 2>&1; then
    log "virtualbox-7.2 já instalado ($(dpkg-query -W -f='${Version}' virtualbox-7.2))"
else
    log "Instalando virtualbox-7.2"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq virtualbox-7.2 >/dev/null
fi

# --- 2. grupo vboxusers ----------------------------------------------------------------
if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx vboxusers; then
    log "$USER_NAME já está no grupo vboxusers"
else
    usermod -aG vboxusers "$USER_NAME"
    log "$USER_NAME adicionado ao grupo vboxusers (vale após novo login)"
fi

# --- 3. KVM: não ligar o VMX ao carregar (senão o VirtualBox falha com VERR_VMX_IN_VMX_ROOT_MODE) ---
KVMCONF=/etc/modprobe.d/kvm-vbox.conf
KMAJ="$(uname -r | cut -d. -f1)"; KMIN="$(uname -r | cut -d. -f2)"
if (( KMAJ > 6 || (KMAJ == 6 && KMIN >= 12) )); then
    if ! grep -qs "enable_virt_at_load=0" "$KVMCONF"; then
        echo "options kvm enable_virt_at_load=0" >"$KVMCONF"
        log "Criado $KVMCONF (options kvm enable_virt_at_load=0)"
    fi
    if [[ "$(cat /sys/module/kvm/parameters/enable_virt_at_load 2>/dev/null || echo N)" == Y ]]; then
        # recarrega o kvm agora, se nada estiver usando; senão vale após o reboot
        if modprobe -r kvm_intel kvm_amd kvm 2>/dev/null; then
            modprobe kvm 2>/dev/null || true
            log "kvm recarregado com enable_virt_at_load=0"
        else
            log "kvm em uso; a opção vale após o reboot"; REBOOT=1
        fi
    fi
else
    log "Kernel $(uname -r) < 6.12: ajuste do kvm não é necessário"
fi

# --- 4. Secure Boot: módulos assinados com a MOK ---------------------------------------------
MOK_DIR=/var/lib/shim-signed/mok
if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
    if [[ ! -f "$MOK_DIR/MOK.der" || ! -f "$MOK_DIR/MOK.priv" ]]; then
        # o vboxconfig do Ubuntu assina os módulos com esta chave (a mesma do DKMS)
        log "Gerando chave MOK em $MOK_DIR"
        if command -v update-secureboot-policy >/dev/null; then
            update-secureboot-policy --new-key >/dev/null
        else
            mkdir -p "$MOK_DIR"
            openssl req -nodes -new -x509 -newkey rsa:2048 -outform DER -days 36500 -subj "/CN=$(hostname) MOK/" \
                -keyout "$MOK_DIR/MOK.priv" -out "$MOK_DIR/MOK.der" 2>/dev/null
            chmod 600 "$MOK_DIR/MOK.priv"
        fi
    fi
    MOKSTATE="$(mokutil --test-key "$MOK_DIR/MOK.der" 2>&1 || true)"
    if grep -q "is already enrolled" <<<"$MOKSTATE"; then
        log "Chave MOK já registrada no firmware"
    elif grep -q "already in the enrollment request" <<<"$MOKSTATE"; then
        log "Registro da MOK pendente: reinicie, conclua o \"Enroll MOK\" na tela azul e rode de novo: sudo $0"
        exit 0
    else
        cat >&2 <<EOF

Secure Boot ligado: é preciso registrar a chave MOK (uma vez).
  1. Agora o mokutil vai pedir uma senha temporária (invente uma e anote).
  2. Reinicie. Na tela azul "MOK management": Enroll MOK → Continue → Yes → digite a senha → Reboot.
  3. Depois do reboot, rode de novo: sudo $0
EOF
        mokutil --import "$MOK_DIR/MOK.der"
        exit 0
    fi
else
    log "Secure Boot desligado: assinatura dos módulos não é necessária"
fi
log "Compilando e carregando os módulos do VirtualBox (vboxconfig)"
/sbin/vboxconfig >/dev/null || die "vboxconfig falhou; veja /var/log/vbox-setup.log"

# --- 5. verificação --------------------------------------------------------------------------
lsmod | grep -q '^vboxdrv' || die "módulo vboxdrv não carregado (veja /var/log/vbox-setup.log)"
log "VirtualBox $(VBoxManage --version | tail -1); módulos: $(lsmod | awk '/^vbox/{print $1}' | paste -sd' ')"
log "kvm enable_virt_at_load: $(cat /sys/module/kvm/parameters/enable_virt_at_load 2>/dev/null || echo 'kvm não carregado')"
if sudo -u "$USER_NAME" VBoxManage list hostinfo >/dev/null 2>&1; then
    log "VBoxManage ok para $USER_NAME"
else
    log "AVISO: VBoxManage falhou para $USER_NAME; faça logout/login (grupo vboxusers) e teste: VBoxManage list hostinfo"
fi
(( REBOOT )) && log "Reinicie a máquina para aplicar o ajuste do kvm"
log "Pronto. Próximo passo (sem sudo): ./bootstrap.sh"
