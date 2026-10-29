#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "=== Instalando os pacotes basicos ==="
apt-get update
apt-get install -y \
  apache2 \
  mysql-server \
  git \
  curl \
  ca-certificates \
  gnupg \
  sudo \
  util-linux \
  coreutils \
  procps \
  hostname \
  python3

echo "=== Criando o usuario da aplicacao ==="
if ! id envweb >/dev/null 2>&1; then
  useradd --system --user-group --no-create-home \
    --shell /usr/sbin/nologin envweb
fi

echo "=== Preparando a pasta dos scripts enviados ==="
install -d -o root -g root -m 755 /var/lib/envs
install -d -o envweb -g envweb -m 750 /var/lib/envs/scripts

echo "=== Instalando o Node.js 20 ==="
NODE_SETUP=$(mktemp)

curl -fsSL https://deb.nodesource.com/setup_20.x -o "$NODE_SETUP"
bash "$NODE_SETUP"
rm -f "$NODE_SETUP"

apt-get install -y nodejs

echo "=== Conferindo Node.js e npm ==="
node --version
npm --version

echo "=== Baixando o projeto do GitHub ==="

REPO_URL="https://github.com/OtavioAugusto04/Proj2-Computacao-em-Nuvem.git"
REPO_DIR="/opt/projeto2"
REPO_BRANCH="${1:-main}"

if [ ! -d "$REPO_DIR" ]; then
  git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
else
  if [ ! -d "$REPO_DIR/.git" ]; then
    echo "ERRO: $REPO_DIR existe, mas nao e um repositorio Git."
    exit 1
  fi

  git -C "$REPO_DIR" fetch origin
  git -C "$REPO_DIR" checkout "$REPO_BRANCH"
  git -C "$REPO_DIR" pull --ff-only origin "$REPO_BRANCH"
fi

echo "=== Versao do codigo baixado ==="
git -C "$REPO_DIR" log -1 --oneline

echo "=== Configurando o banco de dados ==="

systemctl enable --now mysql

SCHEMA_FILE="$REPO_DIR/provision/mysql/schema.sql"

if [ ! -f "$SCHEMA_FILE" ]; then
  echo "ERRO: arquivo do banco nao encontrado: $SCHEMA_FILE"
  exit 1
fi

mysql < "$SCHEMA_FILE"

echo "=== Conferindo as tabelas criadas ==="
mysql -e "SHOW TABLES FROM envs;"

echo "=== Criando as credenciais do banco ==="

install -d -o root -g root -m 700 /etc/projeto2
DB_PASS_FILE="/etc/projeto2/db_password"

if [ ! -s "$DB_PASS_FILE" ]; then
  (
    umask 077
    python3 -c 'import secrets; print(secrets.token_hex(24))' > "$DB_PASS_FILE"
  )
fi

DB_PASS=$(cat "$DB_PASS_FILE")

mysql <<SQL
CREATE USER IF NOT EXISTS 'envweb'@'localhost'
  IDENTIFIED BY '${DB_PASS}';

ALTER USER 'envweb'@'localhost'
  IDENTIFIED BY '${DB_PASS}';

GRANT SELECT, INSERT, UPDATE, DELETE ON envs.*
  TO 'envweb'@'localhost';
SQL

echo "=== Configurando a aplicacao web ==="

APP_DIR="$REPO_DIR/app"

if [ ! -f "$APP_DIR/package-lock.json" ]; then
  echo "ERRO: arquivos da aplicacao nao encontrados em $APP_DIR"
  exit 1
fi

install -o root -g envweb -m 640 /dev/null "$APP_DIR/.env"

cat > "$APP_DIR/.env" <<ENV
PORT=3000
HOST=127.0.0.1
DB_HOST=localhost
DB_USER=envweb
DB_PASS=${DB_PASS}
DB_NAME=envs
ENVCTL_PATH=/usr/local/bin/envctl
ENVCTL_SUDO=true
SCRIPTS_DIR=/var/lib/envs/scripts
ENV

echo "=== Instalando as dependencias da aplicacao ==="

(
  cd "$APP_DIR"
  npm ci --omit=dev
)

echo "=== Instalando o motor envctl ==="

ENGINE_FILE="$REPO_DIR/engine/envctl"
SUDOERS_FILE="$REPO_DIR/provision/sudoers/envctl"

if [ ! -f "$ENGINE_FILE" ]; then
  echo "ERRO: motor nao encontrado: $ENGINE_FILE"
  exit 1
fi

if [ ! -f "$SUDOERS_FILE" ]; then
  echo "ERRO: arquivo sudoers nao encontrado: $SUDOERS_FILE"
  exit 1
fi

install -o root -g root -m 755 \
  "$ENGINE_FILE" /usr/local/bin/envctl

echo "=== Configurando a permissao do aplicativo ==="

visudo -cf "$SUDOERS_FILE"

install -o root -g root -m 440 \
  "$SUDOERS_FILE" /etc/sudoers.d/envctl

visudo -c

echo "=== Configurando o servico da aplicacao ==="

install -o root -g root -m 644 \
  "$REPO_DIR/provision/systemd/envweb.service" \
  /etc/systemd/system/envweb.service

systemctl daemon-reload
systemctl enable envweb
systemctl restart envweb

echo "=== Configurando o Apache ==="

install -o root -g root -m 644 \
  "$REPO_DIR/provision/apache/envs.conf" \
  /etc/apache2/sites-available/envs.conf

a2enmod proxy proxy_http
a2dissite 000-default
a2ensite envs

apache2ctl configtest

systemctl enable apache2
systemctl restart apache2

echo "=== Conferindo os servicos ==="

systemctl is-active mysql
systemctl is-active envweb
systemctl is-active apache2