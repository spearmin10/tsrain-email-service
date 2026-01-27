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

if [ -f /etc/systemd/system/zram-swap.service ]; then
  systemctl stop zram-swap 2> /dev/null
  systemctl disable zram-swap 2> /dev/null
  swapoff /dev/zram0 2> /dev/null
  sleep 5
  modprobe -r zram
  rm -f /etc/systemd/system/zram-swap.service 2> /dev/null
fi

swapoff /swapfile 2> /dev/null
sed -i '\|/swapfile |d' /etc/fstab 2> /dev/null
rm -f /swapfile

rm -rf "${TSRAIN_HOME}"

echo "*** Uninstallation Finished. ***"
