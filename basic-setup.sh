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

if [[ -d /etc/ssh/sshd_config.d ]]; then
  tar -czf "/etc/ssh/sshd_config.d.backup.$(date +%F-%H%M%S).tar.gz" /etc/ssh/sshd_config.d
fi

echo "==> Проверяю наличие SSH ключей..."
CURRENT_USER="${SUDO_USER:-root}"

HAS_KEY="false"

if [[ "${CURRENT_USER}" != "root" && -f "/home/${CURRENT_USER}/.ssh/authorized_keys" ]]; then
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

echo "==> Настраиваю SSH только на порт ${SSH_PORT}..."

mkdir -p /etc/ssh/sshd_config.d

# Убираем возможные Port 22 / Port ... из основного конфига,
# чтобы итоговый порт контролировался только нашим hardening-файлом.
sed -i -E 's/^[[:space:]]*Port[[:space:]]+[0-9]+/# & # disabled by secure-ubuntu.sh/' /etc/ssh/sshd_config

# На всякий случай гарантируем Include.
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
fi

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

mkdir -p /run/sshd
chmod 0755 /run/sshd

sshd -t

echo "==> Отключаю ssh.socket, чтобы SSH не оставался на 22 порту..."

systemctl disable --now ssh.socket 2>/dev/null || true
systemctl mask ssh.socket 2>/dev/null || true

echo "==> Включаю обычный ssh.service..."

systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true

echo "==> Перезапускаю SSH..."

if systemctl list-unit-files | grep -q '^ssh.service'; then
  systemctl restart ssh
elif systemctl list-unit-files | grep -q '^sshd.service'; then
  systemctl restart sshd
else
  echo "❌ Не найден ssh.service или sshd.service"
  exit 1
fi

echo "==> Проверяю, что SSH реально слушает только порт ${SSH_PORT}..."

sleep 2

SSH_LISTEN="$(ss -tlnp | grep -E 'sshd|:22|:'"${SSH_PORT}" || true)"
echo "${SSH_LISTEN}"

if ! ss -tlnp | grep -qE ":${SSH_PORT}[[:space:]].*sshd"; then
  echo "❌ sshd не слушает порт ${SSH_PORT}."
  echo "Аварийно открываю 22 порт в UFW, чтобы не потерять доступ."
  ufw allow 22/tcp || true
  exit 1
fi

if ss -tlnp | grep -qE ':22[[:space:]].*sshd'; then
  echo "❌ sshd всё ещё слушает 22 порт."
  echo "Проверь:"
  echo "  grep -R \"^Port\" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf"
  echo "  systemctl status ssh.socket"
  exit 1
fi

echo "==> Настраиваю UFW..."

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp

ufw delete allow 22/tcp 2>/dev/null || true

ufw --force enable

echo "==> Проверяю UFW..."

if ! ufw status verbose | grep -q "${SSH_PORT}/tcp"; then
  echo "❌ UFW не содержит правило для ${SSH_PORT}/tcp."
  echo "Аварийно открываю 22 порт."
  ufw allow 22/tcp || true
  exit 1
fi

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

echo "==> Финальная проверка SSH..."

sshd -t

if ! ss -tlnp | grep -qE ":${SSH_PORT}[[:space:]].*sshd"; then
  echo "❌ Финальная проверка провалена: sshd не слушает ${SSH_PORT}."
  ufw allow 22/tcp || true
  exit 1
fi

if ss -tlnp | grep -qE ':22[[:space:]].*sshd'; then
  echo "❌ Финальная проверка провалена: sshd всё ещё слушает 22."
  exit 1
fi

echo
echo "✅ Готово."
echo
echo "SSH теперь только на порту:"
echo "  ${SSH_PORT}"
echo
echo "Подключение:"
echo "  ssh -p ${SSH_PORT} ${CURRENT_USER}@YOUR_SERVER_IP"
echo
echo "UFW открыт только для:"
echo "  ${SSH_PORT}/tcp: открыт"
echo "  80/tcp: открыт"
echo "  443/tcp: открыт"
echo "  22/tcp: закрыт"
echo
echo "Проверка на сервере:"
echo "  ss -tlnp | grep ssh"
echo "  ufw status verbose"
echo "  fail2ban-client status sshd"
echo
echo "Важно: НЕ закрывай текущую SSH-сессию, пока не проверишь новый вход:"
echo "  ssh -p ${SSH_PORT} ${CURRENT_USER}@YOUR_SERVER_IP"
echo
echo "Если используется firewall провайдера, отдельно открой TCP ${SSH_PORT} в панели провайдера."
