#!/usr/bin/env bash
# 在 roothide/theos 环境下构建 MW16
set -euo pipefail

if [[ -z "${THEOS:-}" ]]; then
  echo "THEOS 未设置。请先安装 roothide/theos：" >&2
  echo '  bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"' >&2
  exit 1
fi

export THEOS_PACKAGE_SCHEME=roothide
export ARCHS="arm64 arm64e"
export TARGET=iphone:clang:16.5:15.0

cd "$(dirname "$0")"
make clean package

ls -1 packages/*.deb
