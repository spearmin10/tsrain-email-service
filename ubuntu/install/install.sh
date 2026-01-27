#!/bin/bash

CONTAINER_NAME=tsrain
TSRAIN_HOME=/opt/tsrain
TSRAIN_PKI_DIR=${TSRAIN_HOME}/pki
TSRAIN_ETC_DIR=${TSRAIN_HOME}/etc
TSRAIN_BIN_DIR=${TSRAIN_HOME}/bin
TSRAIN_CREDS_DIR=/var/opt/tsrain/services/${CONTAINER_NAME}
TSRAIN_MAILBOX_PASSWORD=${TSRAIN_MAILBOX_PASSWORD:-TsrainDefault0!}
RAINLOOP_CREDS_FILE=credentials.json
RAINLOOP_DEFAULT_ADMIN_PASSWORD_FILE=rainloop-default-admin-password.txt

usage_exit() {
  echo "Usage: $0 [-m] [-h]" 1>&2
  exit 1
}

error_exit() {
  echo "Installation Failed." 1>&2
  exit 1
}

install_system_packages() {
  apt-get update
  apt-get install -y jq gettext openssl || error_exit

  # Uninstall old docker packages
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc
  do
    apt-get remove $pkg
  done

  # Add Docker's official GPG key:
  apt-get install -y ca-certificates curl || error_exit
  install -m 0755 -d /etc/apt/keyrings || error_exit
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc || error_exit
  chmod a+r /etc/apt/keyrings/docker.asc || error_exit

  # Add the repository to Apt sources:
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update

  # Install the latest docker packages
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || error_exit

  systemctl enable docker
  systemctl start docker
  groupadd docker
  usermod -a -G docker $(whoami)
  systemctl restart docker
}

configire_tsrain_service() {
  RAINLOOP_CREDENTIALS_PATH="${TSRAIN_CREDS_DIR}/${RAINLOOP_CREDS_FILE}"
  RAINLOOP_DEFAULT_ADMIN_PASSWORD=`openssl rand -base64 24`

  TSRAIN_IMAGE_LATEST_VERSION=`curl -s https://registry.hub.docker.com/v2/repositories/spearmint/tsrain/tags | jq -r '.results[].name' | grep -v "^latest$" | sort -r --version-sort | head -1`
  if [ -z "${TSRAIN_IMAGE_LATEST_VERSION}" ]; then
    error_exit
  fi

  cat << __EOT__ > ${TSRAIN_ETC_DIR}/.env || error_exit
TSRAIN_PKI_DIR=${TSRAIN_PKI_DIR}
RAINLOOP_CREDENTIALS_PATH=${RAINLOOP_CREDENTIALS_PATH}
RAINLOOP_DEFAULT_ADMIN_PASSWORD=${RAINLOOP_DEFAULT_ADMIN_PASSWORD}
__EOT__

  chmod 600 ${TSRAIN_ETC_DIR}/.env

  export TSRAIN_IMAGE_LATEST_VERSION
  cat << '__EOT__' | envsubst '$TSRAIN_IMAGE_LATEST_VERSION' > ${TSRAIN_ETC_DIR}/docker-compose.yml || error_exit
services:
    tsrain:
        image: spearmint/tsrain:${TSRAIN_IMAGE_LATEST_VERSION}
        container_name: tsrain
        restart: always
        mem_limit: 384m
        memswap_limit: 2g
        environment:
            - RAINLOOP_DEFAULT_ADMIN_PASSWORD=${RAINLOOP_DEFAULT_ADMIN_PASSWORD}
        volumes:
            - ${TSRAIN_PKI_DIR}/server.key.pem:/usr/local/etc/pki/server.key.pem
            - ${TSRAIN_PKI_DIR}/server.chain.pem:/usr/local/etc/pki/server.chain.pem
            - ${TSRAIN_PKI_DIR}/client.calist.pem:/usr/local/etc/pki/client.calist.pem
            - ${RAINLOOP_CREDENTIALS_PATH}:/var/opt/testserv/credentials.json
        ports:
            - "25:25"
            - "80:80"
            - "143:143"
            - "443:444"
            - "465:465"
            - "993:993"
            - "4433:443"
__EOT__

  cat << __EOT__ > /etc/systemd/system/tsrain.service || error_exit
[Unit]
Description = TSRAIN Web Mail
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=${TSRAIN_ETC_DIR}
ExecStart=docker compose up -d
ExecStop=docker compose down
RemainAfterExit=yes
TimeoutStartSec=0

[Install]
WantedBy = multi-user.target
__EOT__

  systemctl enable tsrain

  if [ ! -f ${RAINLOOP_CREDENTIALS_PATH} ]; then
    jq --arg password "${TSRAIN_MAILBOX_PASSWORD}" -n '."*".password = $password' > ${RAINLOOP_CREDENTIALS_PATH}
  fi
  chmod 600 ${RAINLOOP_CREDENTIALS_PATH}
}

issue_certificates() {
  cd ${TSRAIN_PKI_DIR}

  openssl req \
   -newkey ec:<(openssl ecparam -name prime256v1) \
   -nodes \
   -subj "/C=JP/O=Spearmint/CN=TSRAIN Root CA" \
   -keyout tsrain-root.key.pem | \
    openssl x509 -req \
     -signkey tsrain-root.key.pem  \
     -days 730 \
     -extensions EXTS -extfile <(printf "[EXTS]\nkeyUsage=critical,cRLSign,digitalSignature,keyCertSign\nsubjectKeyIdentifier=hash\nbasicConstraints=critical,CA:TRUE") \
     -out tsrain-root.cer.pem || error_exit

  openssl req \
   -newkey ec:<(openssl ecparam -name prime256v1) \
   -nodes \
   -subj "/C=JP/O=Spearmint/CN=TSRAIN Service" \
   -keyout tsrain-svc.key.pem | \
    openssl x509 -req \
     -CA tsrain-root.cer.pem \
     -CAkey tsrain-root.key.pem \
     -set_serial 0x$(openssl rand -hex 16) \
     -days 365 \
     -extensions EXTS -extfile <(printf "[EXTS]\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\nbasicConstraints=critical,CA:FALSE") \
     -out tsrain-svc.cer.pem || error_exit

  for name in smtp imap4 rainloop
  do
    openssl req \
     -newkey ec:<(openssl ecparam -name prime256v1) \
     -nodes \
     -subj "/C=JP/O=Spearmint/CN=${name}-client" \
     -keyout tsrain-${name}-client.key.pem | \
      openssl x509 -req \
       -CA tsrain-root.cer.pem \
       -CAkey tsrain-root.key.pem \
       -set_serial 0x$(openssl rand -hex 16) \
       -days 365 \
       -extensions EXTS -extfile <(printf "[EXTS]\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\nbasicConstraints=critical,CA:FALSE") \
       -out tsrain-${name}-client.cer.pem || error_exit
    chmod 600 tsrain-${name}-client.key.pem || error_exit
  done

  cp -f tsrain-svc.cer.pem server.cer.pem || error_exit
  cp -f tsrain-svc.key.pem server.key.pem || error_exit
  cp -f tsrain-root.cer.pem client.calist.pem || error_exit
  cat tsrain-svc.cer.pem tsrain-root.cer.pem > server.chain.pem || error_exit
  chmod 600 *.key.pem || error_exit
}


if [ "$(id -u)" -ne 0 ]; then
  echo "The script must be run as root"
  exit 1
fi

mkdir -p ${TSRAIN_BIN_DIR} || error_exit
mkdir -p ${TSRAIN_ETC_DIR} || error_exit
mkdir -p ${TSRAIN_PKI_DIR} || error_exit
mkdir -p ${TSRAIN_CREDS_DIR} || error_exit

### Setup System
install_system_packages

### Setup TSRAIN
configire_tsrain_service

### Setup SSL Frontend
issue_certificates

### Start TSRAIN
systemctl restart tsrain || error_exit

echo "*** Installation complete, and the TSRAIN service has started. ***"

