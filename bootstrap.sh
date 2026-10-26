#!/usr/bin/env bash
set -euo pipefail

FLUFFY=/mnt/fluffy

if ! mountpoint -q "$FLUFFY"
then
    mount "$FLUFFY"
fi

if ! id -u builder &>/dev/null
then
    useradd -m -U -s /bin/bash builder
fi

mkdir -pv /sw
mkdir -pv /work
mkdir -pv "$FLUFFY/sw"
mkdir -pv "$FLUFFY/work"
