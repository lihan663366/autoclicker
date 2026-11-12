#!/usr/bin/env bash
# 一键编译（macOS / Linux WSL 均可，需要已装好 Theos）
set -euo pipefail

export THEOS="${THEOS:-$HOME/theos}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

if [ ! -d "$THEOS/makefiles" ]; then
    echo "✗ 找不到 Theos：$THEOS"
    echo "  安装："
    echo "    export THEOS=\$HOME/theos"
    echo "    git clone --recursive https://github.com/theos/theos.git \$THEOS"
    echo "    git clone --depth 1 https://github.com/theos/sdks /tmp/sdks"
    echo "    mkdir -p \$THEOS/sdks && cp -R /tmp/sdks/*.sdk \$THEOS/sdks/"
    exit 1
fi

if ! ls "$THEOS/sdks"/*.sdk >/dev/null 2>&1; then
    echo "✗ $THEOS/sdks 里没有 iOS SDK"
    echo "    git clone --depth 1 https://github.com/theos/sdks /tmp/sdks"
    echo "    mkdir -p \$THEOS/sdks && cp -R /tmp/sdks/*.sdk \$THEOS/sdks/"
    exit 1
fi

make clean >/dev/null 2>&1 || true
make package FINALPACKAGE=1

echo
echo "✓ 产物："
ls -lh packages/*.deb 2>/dev/null || echo "  （没找到 deb，检查上面的编译输出）"
