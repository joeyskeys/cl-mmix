#!/usr/bin/env bash
# Idempotent Cloud Agent bootstrap for cl-mmix.
# Installs SBCL (the only system dependency) and warms the ASDF fasl cache.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v sbcl >/dev/null 2>&1; then
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends sbcl
fi

sbcl --version

# Compile the system so fasls are cached and any load-time errors surface early.
sbcl --non-interactive \
     --eval '(require :asdf)' \
     --eval '(pushnew (truename ".") asdf:*central-registry* :test (function equal))' \
     --eval '(asdf:compile-system :cl-mmix)' \
     --eval '(asdf:load-system :cl-mmix)' \
     --eval '(sb-ext:exit :code 0)'

echo "cl-mmix environment ready."
