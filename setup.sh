#!/usr/bin/env bash
# setup.sh — install dependencies and build both benchmarks from scratch.
# Supports Debian/Ubuntu (apt) and RHEL/Fedora (dnf). Run with sudo for installs.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "### THP demo setup ###"

install_apt() {
  apt-get update
  apt-get install -y default-jdk build-essential \
    linux-tools-common "linux-tools-$(uname -r)" || \
    apt-get install -y default-jdk build-essential linux-tools-generic
  # Optional (Redis example) — non-fatal if unavailable:
  apt-get install -y redis-server || true
  apt-get install -y memtier-benchmark || \
    echo "  [note] memtier-benchmark not in apt; build from github.com/RedisLabs/memtier_benchmark for run_redis.sh"
}

install_dnf() {
  dnf install -y java-latest-openjdk-devel gcc make perf || true
  dnf install -y redis || true
  echo "  [note] memtier-benchmark: build from github.com/RedisLabs/memtier_benchmark for run_redis.sh"
}

if command -v apt-get >/dev/null 2>&1; then
  if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo for package installs"; else install_apt; fi
elif command -v dnf >/dev/null 2>&1; then
  if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo for package installs"; else install_dnf; fi
else
  echo "Unknown package manager — install OpenJDK 17+, gcc/make, and linux perf manually."
fi

echo "### building ###"
make -C "$REPO"

echo
echo "Done. Try:  sudo ./scripts/run_micro.sh"
echo "       or:  sudo ./scripts/run_jvm.sh"
