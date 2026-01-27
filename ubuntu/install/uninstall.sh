#!/bin/sh

TSRAIN_HOME=/opt/tsrain

if [ "$(id -u)" -ne 0 ]; then
  echo "The script must be run as root"
  exit 1
fi

systemctl stop tsrain 2> /dev/null
systemctl disable tsrain 2> /dev/null
rm -f /etc/systemd/system/tsrain.service 2> /dev/null

docker images spearmint/tsrain --format "{{.Repository}}:{{.Tag}}" | xargs -r docker rmi -f 2> /dev/null

rm -rf "${TSRAIN_HOME}"

echo "*** Uninstallation Finished. ***"
