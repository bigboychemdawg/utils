#!/usr/bin/env bash
set -euo pipefail

SSH_PORT="2233"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Запусти через sudo: sudo bash secure-ubuntu.sh"
  exit 1
fi

echo "==> Проверяю Ubuntu..."
if ! grep -qi "ubuntu" /etc/os-release; then
  echo "Этот скрипт рассчитан на Ubuntu."
  exit 1
fi

echo "==> Устанавливаю пакеты..."
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold" \
  openssh-server ufw fail2ban

echo "==> Создаю backup sshd_config..."
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%F-%H%M%S)"

echo "==> Проверяю наличие SSH ключей..."
CURRENT_USER="${SUDO_USER:-root}"

HAS_KEY="false"

if [[ -f "/home/${CURRENT_USER}/.ssh/authorized_keys" ]]; then
  HAS_KEY="true"
fi

if [[ -f "/root/.ssh/authorized_keys" ]]; then
  HAS_KEY="true"
fi

if [[ "${HAS_KEY}" != "true" ]]; then
  echo "❌ Не найден authorized_keys."
  echo "Сначала добавь SSH-ключ, иначе можно потерять доступ к серверу."
  exit 1
fi

echo "==> Настраиваю SSH порт ${SSH_PORT} и запрет root password login..."

mkdir -p /etc/ssh/sshd_config.d

cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
EOF

echo "==> Проверяю SSH config..."
sshd -t

echo "==> Настраиваю UFW..."
ufw --force reset

ufw default deny incoming
ufw default allow outgoing

ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp

ufw --force enable

echo "==> Настраиваю fail2ban..."

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
logpath = %(sshd_log)s
maxretry = 5
EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo "==> Перезапускаю SSH..."
systemctl restart ssh || systemctl restart sshd

echo
echo "✅ Готово."
echo
echo "SSH теперь на порту:"
echo "  ${SSH_PORT}"
echo
echo "Подключение:"
echo "  ssh -p ${SSH_PORT} ${CURRENT_USER}@YOUR_SERVER_IP"
echo
echo "UFW открыт только для:"
echo "  22/tcp: закрыт"
echo "  ${SSH_PORT}/tcp: открыт"
echo "  80/tcp: открыт"
echo "  443/tcp: открыт"
echo
echo "Проверка:"
echo "  ufw status verbose"
echo "  fail2ban-client status sshd"
echo
echo "Важно: НЕ закрывай текущую SSH-сессию, пока не проверишь новый вход через:"
echo "  ssh -p ${SSH_PORT} ${CURRENT_USER}@YOUR_SERVER_IP"
