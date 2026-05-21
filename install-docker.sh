#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Запусти через sudo: sudo bash install-docker.sh"
  exit 1
fi

if ! grep -qi "ubuntu" /etc/os-release; then
  echo "Этот скрипт рассчитан на Ubuntu."
  exit 1
fi

echo "==> Обновляю apt..."
apt-get update -y

echo "==> Ставлю зависимости..."
apt-get install -y ca-certificates curl gnupg

echo "==> Добавляю GPG ключ Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "==> Добавляю Docker apt repository..."
. /etc/os-release

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

echo "==> Устанавливаю Docker Engine + Compose plugin..."
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> Включаю Docker в автозагрузку..."
systemctl enable docker
systemctl start docker

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  echo "==> Добавляю пользователя ${SUDO_USER} в группу docker..."
  usermod -aG docker "${SUDO_USER}"
fi

echo
echo "✅ Docker установлен:"
docker --version

echo
echo "✅ Docker Compose установлен:"
docker compose version

echo
echo "Готово."
echo "Важно: чтобы docker работал без sudo, перелогинься по SSH или выполни:"
echo "  newgrp docker"