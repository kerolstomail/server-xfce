#!/bin/bash

# setup.sh — تثبيت حزم، إصلاح apt/dpkg، ضبط SSH، إنشاء user1.
# تحذير: يمنح user1 وصول كامل.

set -uo pipefail

LOG="/var/log/setup_user_friendly_final.log"
RUNLOG="/var/log/setup_run.log"
SUCCESS_LOG="/var/log/setup_success.log"
FAILED_LOG="/var/log/setup_failed.log"

# تهيئة ملفات اللوج
: > "$LOG"
: > "$RUNLOG"
: > "$SUCCESS_LOG"
: > "$FAILED_LOG"
chmod 644 "$LOG" 2>/dev/null || true

SUCCESS=0
FAILED=0
START_TS=$(date +%s)

inc_success(){ SUCCESS=$((SUCCESS+1)); echo "$1" >> "$SUCCESS_LOG"; }
inc_failed(){ FAILED=$((FAILED+1)); echo "$1" >> "$FAILED_LOG"; }

# دالة التشغيل
run() {
    local desc="$1"; shift
    echo "" >> "$LOG" "$RUNLOG"
    echo "----" >> "$LOG" "$RUNLOG"
    echo "Executing: $desc" >> "$LOG" "$RUNLOG"
    echo "----" | tee -a "$LOG" "$RUNLOG"
    bash -c "$*" 2>&1 | tee -a "$LOG" "$RUNLOG"
    rc=$?
    if [ $rc -eq 0 ]; then
        echo "SUCCESS: $desc" | tee -a "$LOG" "$RUNLOG"
        inc_success "$desc"
    else
        echo "FAILED($rc): $desc" | tee -a "$LOG" "$RUNLOG"
        inc_failed "$desc"
    fi
    echo "========================================" | tee -a "$LOG" "$RUNLOG"
    return $rc
}

# دالة إعادة المحاولة لـ apt
retry_apt() {
    local desc="$1"; shift
    local cmd="$*"
    local tries=0
    local max=3
    local rc=1
    echo "" | tee -a "$LOG" "$RUNLOG"
    echo "Executing (retry): $desc" | tee -a "$LOG" "$RUNLOG"
    while [ $tries -lt $max ]; do
        echo "Attempt $((tries+1))..." | tee -a "$LOG" "$RUNLOG"
        dpkg --configure -a 2>&1 | tee -a "$LOG" "$RUNLOG" || true
        apt-get -f install -y 2>&1 | tee -a "$LOG" "$RUNLOG" || true
        bash -c "$cmd" 2>&1 | tee -a "$LOG" "$RUNLOG"
        rc=$?
        if [ $rc -eq 0 ]; then
            echo "SUCCESS: $desc (attempt $((tries+1)))" | tee -a "$LOG" "$RUNLOG"
            inc_success "$desc"
            echo "========================================" | tee -a "$LOG" "$RUNLOG"
            return 0
        fi
        tries=$((tries+1))
        echo "Attempt $tries failed for: $desc (rc=$rc). Retrying in 5s..." | tee -a "$LOG" "$RUNLOG"
        sleep 5
    done
    echo "FAILED(final): $desc (rc=$rc)" | tee -a "$LOG" "$RUNLOG"
    inc_failed "$desc"
    echo "========================================" | tee -a "$LOG" "$RUNLOG"
    return $rc
}

enable_ufw_safely() {
    if ! command -v ufw >/dev/null 2>&1; then
        retry_apt "install ufw" "apt-get install -y ufw || true"
    fi
    virt=$(systemd-detect-virt 2>/dev/null || echo "none")
    case "$virt" in
        none|kvm|qemu|vmware) ;;
        *)
            echo "Notice: virtual env ($virt) — skipping ufw enable" | tee -a "$LOG" "$RUNLOG"
            return 1
            ;;
    esac
    bash -c "ufw default deny incoming" 2>&1 | tee -a "$LOG" || true
    bash -c "ufw default allow outgoing" 2>&1 | tee -a "$LOG" || true
    bash -c "ufw allow 22/tcp" 2>&1 | tee -a "$LOG" || true
    bash -c "ufw allow 'Apache Full' || true" 2>&1 | tee -a "$LOG" || true
    bash -c "ufw --force enable" 2>&1 | tee -a "$LOG" || { echo "ufw enable failed" | tee -a "$LOG" "$RUNLOG"; return 1; }
    echo "ufw enabled" | tee -a "$LOG" "$RUNLOG"
    return 0
}

# التحقق من الروت
if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root." | tee -a "$LOG" "$RUNLOG"
    exit 1
fi

# نسخ احتياطي
BACKUP_DIR="/root/setup_backups_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a /etc/sudoers.d "$BACKUP_DIR/" 2>/dev/null || true
cp -a /etc/sudoers "$BACKUP_DIR/sudoers.orig" 2>/dev/null || true

# إصلاح سريع وبدء التحديث
run "dpkg --configure -a (start)" "dpkg --configure -a || true"
run "apt-get update (start)" "apt-get update -o Acquire::Retries=3 || true"

# الحزم
PACKAGES=(
apt-transport-https ca-certificates gnupg wget curl software-properties-common
build-essential dpkg-dev locales vim nano less net-tools iputils-ping dnsutils
sudo acl ufw apache2 apache2-utils openssl openssh-server xrdp xorgxrdp xorg
xserver-xorg-core xfce4 xfce4-goodies xfce4-terminal mate-core mate-desktop-environment
mate-notification-daemon tango-icon-theme gdebi-core matchbox-keyboard xvkbd
htop stacer gnome-system-monitor vnstat at atop rsyslog logrotate unzip zip
policykit-1 python3 python3-pip firefox-esr
)

for pkg in "${PACKAGES[@]}"; do
    retry_apt "install package: $pkg" "DEBIAN_FRONTEND=noninteractive apt-get install -y $pkg -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold' || true"
done

# تحديث نهائي
run "apt-get update (final)" "apt-get update -o Acquire::Retries=3 || true"
run "apt-get upgrade (final)" "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || true"

# UFW
enable_ufw_safely || true
run "ufw allow 22/tcp" "ufw allow 22/tcp || true"
run "ufw allow 'Apache Full'" "ufw allow 'Apache Full' || true"
run "ufw allow 3389/tcp" "ufw allow 3389/tcp || true"

# تشغيل الخدمات
SERVICES=(apache2 ssh xrdp vnstat rsyslog)
for s in "${SERVICES[@]}"; do
    run "enable service: $s" "systemctl enable $s || true"
    run "start service: $s" "systemctl start $s || true"
done

# === SSH ===
run "fix sudo.conf perms" "chown root:root /etc/sudo.conf 2>/dev/null || true; chmod 644 /etc/sudo.conf 2>/dev/null || true"
run "fix ssh keys perms" "chown root:root /etc/ssh/ssh_host_* 2>/dev/null || true; chmod 600 /etc/ssh/ssh_host_* 2>/dev/null || true"
run "grant user1 read keys" "setfacl -m u:user1:r-- /etc/ssh/ssh_host_* 2>/dev/null || true"
run "regen ssh keys if needed" 'if [ -x "$(command -v dpkg-reconfigure)" ]; then dpkg-reconfigure openssh-server || true; else ssh-keygen -A || true; fi'
run "restart ssh" "systemctl restart ssh || true"

# === إنشاء المستخدم ===
run "create user1" "id -u user1 >/dev/null 2>&1 || useradd -m -s /bin/bash user1"
run "set user1 password" "echo 'user1:Kerols12@' | chpasswd || true"
run "add user1 to sudo" "usermod -aG sudo user1 || true"
run "create adminfiles" "getent group adminfiles >/dev/null 2>&1 || groupadd adminfiles || true; usermod -aG adminfiles user1 || true; mkdir -p /root/writecode; chown -R root:adminfiles /root/writecode || true; chmod -R 2775 /root/writecode || true; touch /root/writecode/copy.txt || true"

# Sudoers
SUDOERS_FILE="/etc/sudoers.d/90-user1"
echo "user1 ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE" || true
inc_success "create sudoers file for user1"

# === ACLs ===
run "ACLs /root" "setfacl -R -m u:user1:rwx /root || true; setfacl -R -d -m u:user1:rwx /root || true"

# Swap
SWAPFILE="/swapfile"
if [ ! -f "$SWAPFILE" ]; then
    run "create swap 1.5G" "dd if=/dev/zero of=$SWAPFILE bs=1M count=1536 status=none; chmod 600 $SWAPFILE; mkswap $SWAPFILE; swapon $SWAPFILE; grep -qF '$SWAPFILE' /etc/fstab || echo '$SWAPFILE none swap sw 0 0' >> /etc/fstab"
fi

# Vnstat
IFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
IFACE=${IFACE:-eth0}
run "vnstat" "vnstat --create -i $IFACE || true; systemctl restart vnstat || true"

# TeamViewer
TV_DEB="/tmp/teamviewer_amd64.deb"
run "download TV" "wget -O $TV_DEB https://download.teamviewer.com/download/linux/teamviewer_amd64.deb || true"
if [ -f "$TV_DEB" ]; then
    run "install TV" "apt-get install -y $TV_DEB || apt-get --fix-broken install -y || true"
fi

# تنظيف نهائي
run "autoremove" "apt-get autoremove -y || true"
run "clean" "apt-get clean || true"

# النهاية
END_TS=$(date +%s)
ELAPSED=$((END_TS-START_TS))
echo "DONE in ${ELAPSED}s. Log: $LOG"
