#!/bin/sh

TSRAIN_DOCKER_COMPOSE=/opt/tsrain/etc/docker-compose.yml

error_exit() {
  echo "Update Failed." 1>&2
  exit 1
}

if [ "$(id -u)" -ne 0 ]; then
  echo "The script must be run as root"
  exit 1
fi

TSRAIN_LATEST_VERSION=`curl -s https://registry.hub.docker.com/v2/repositories/spearmint/tsrain/tags | jq -r '.results[].name' | grep -v "^latest$" | sort -r --version-sort | head -1`
if [ -z "${TSRAIN_LATEST_VERSION}" ]; then
  error_exit
fi

if [ ! -f "${TSRAIN_DOCKER_COMPOSE}" ]; then
  echo "File not found: ${TSRAIN_DOCKER_COMPOSE}"
  exit 1
fi

grep "image: *spearmint/tsrain:${TSRAIN_LATEST_VERSION}" "${TSRAIN_DOCKER_COMPOSE}" > /dev/null
if [ $? -eq 0 ]; then
  echo "There's no update available."
  exit 0
fi

sed -i "s#spearmint/tsrain:.*#spearmint/tsrain:${TSRAIN_LATEST_VERSION}#" "${TSRAIN_DOCKER_COMPOSE}" || error_exit

systemctl restart tsrain

echo "Update complete."
