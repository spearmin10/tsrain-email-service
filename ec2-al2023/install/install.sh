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
  dnf install -y jq gettext docker || error_exit
  systemctl enable docker
  systemctl start --no-block docker
  usermod -a -G docker ec2-user
  systemctl restart --no-block docker

  if [ ! -f /usr/bin/docker-compose ]; then
    COMPOSE_LATEST_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r '.tag_name')
    curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_LATEST_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
      -o /usr/local/bin/docker-compose || error_exit
    chmod +x /usr/local/bin/docker-compose
    ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
  fi
}

configure_file_swap() {
  if [ -z "$(swapon --show=TYPE | grep "^file$")" ]; then
    SWAP_FILEPATH=/swapfile
    rm -f ${SWAP_FILEPATH}
    dd if=/dev/zero of=${SWAP_FILEPATH} bs=1M count=2048 || error_exit
    chmod 600 ${SWAP_FILEPATH} || error_exit
    mkswap ${SWAP_FILEPATH} || error_exit
    swapon ${SWAP_FILEPATH} || error_exit
    echo "${SWAP_FILEPATH} swap swap defaults 0 0" >> /etc/fstab || error_exit
  fi
}

configure_zram_swap_service() {
  if [ -z "$(swapon --show=NAME | grep "^/dev/zram")" ]; then
    cat << '__EOT__' > ${TSRAIN_BIN_DIR}/zram-swap.sh || error_exit
#!/bin/sh

ZRAM_PATH=/dev/zram0
if [ -e "${ZRAM_PATH}" ]; then
  echo "${ZRAM_PATH} already exists."
  exit 1
fi

modprobe -r zram
modprobe zram num_devices=1
if [ ! -e "${ZRAM_PATH}" ]; then
  echo "${ZRAM_PATH} is not found."
  exit 1
fi
zramctl "${ZRAM_PATH}" --size "$(($(grep -Po 'MemTotal:\s*\K\d+' /proc/meminfo)/2))KiB"
mkswap "${ZRAM_PATH}"
swapon "${ZRAM_PATH}"
__EOT__
    chmod +x ${TSRAIN_BIN_DIR}/zram-swap.sh

    cat << __EOT__ > /etc/systemd/system/zram-swap.service || error_exit
[Unit]
Description=zram swap
After=multi-user.target

[Service]
Type=oneshot
ExecStart=${TSRAIN_BIN_DIR}/zram-swap.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
__EOT__
    systemctl enable zram-swap
    systemctl start --no-block zram-swap
  fi
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
ExecStart=/usr/bin/docker-compose up -d
ExecStop=/usr/bin/docker-compose down
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

  for i in `seq 1 1 3`; do
    if [ ! -f tsrain-root.cer.pem ]; then
      echo "Generating a self-signed CA..."
      openssl req \
       -newkey ec:<(openssl ecparam -name prime256v1) \
       -nodes \
       -subj "/C=JP/O=Spearmint/CN=TSRAIN Root CA" \
       -keyout tsrain-root.key.pem | \
        openssl x509 -req \
         -signkey tsrain-root.key.pem  \
         -days 730 \
         -extensions EXTS -extfile <(printf "[EXTS]\nkeyUsage=critical,cRLSign,digitalSignature,keyCertSign\nsubjectKeyIdentifier=hash\nbasicConstraints=critical,CA:TRUE") \
         -out tsrain-root.cer.pem
    fi
  done
  if [ ! -f tsrain-root.cer.pem ]; then
    error_exit
  fi

  for i in `seq 1 1 3`; do
    if [ ! -f tsrain-svc.cer.pem ]; then
      echo "Generating a server certificate..."
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
         -out tsrain-svc.cer.pem
    fi
  done
  if [ ! -f tsrain-svc.cer.pem ]; then
    error_exit
  fi

  for name in smtp imap4 rainloop
  do
    for i in `seq 1 1 3`; do
      if [ ! -f tsrain-${name}-client.cer.pem ]; then
        echo "Generating a client certificate for ${name}..."
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
           -out tsrain-${name}-client.cer.pem
      fi
    done
    if [ ! -f tsrain-${name}-client.cer.pem ]; then
      error_exit
    fi
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
echo "Installing system packages..."
install_system_packages

echo "Configuring swap files..."
configure_file_swap

echo "Configuring zram swap..."
configure_zram_swap_service

### Setup TSRAIN
echo "Configuring the TSRAIN service..."
configire_tsrain_service

### Setup SSL Frontend
echo "Configuring certificates..."
issue_certificates

### Start TSRAIN
echo "Starting the TSRAIN service..."
systemctl restart --no-block tsrain || error_exit

echo "*** Installation complete, and the TSRAIN service has started. ***"

