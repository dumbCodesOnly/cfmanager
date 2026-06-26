#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║           CF-MANAGER v3.0 — Cloudflare CLI Dashboard            ║
# ║        Designed for Termux | github-sync | multi-account        ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Features: Workers · KV · D1 · R2 · Durable Objects · GitHub Sync
#           Rollback · Encrypted token storage · Multi-account
#
# Install deps (Termux):
#   pkg install curl jq openssl git nano
#
# Usage: bash cf-manager.sh

set -euo pipefail