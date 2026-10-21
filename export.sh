#!/usr/bin/env bash
set -exuo pipefail
docker build . -t lfs
docker container create --name lfs lfs false
sudo mount /mnt/lfs
sudo docker cp lfs:/ /mnt/lfs/
sudo umount /mnt/lfs
docker container remove lfs
