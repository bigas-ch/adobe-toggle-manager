#!/bin/zsh
# === Backend Interface (v4.3.0) ===
# Spec for discovery backends in Adobe Toggle Manager.
# Each backend is a zsh file and MUST implement the following 6 functions in
# the <backend_name>__ namespace:
#
#   <name>__name()
#       → prints the backend name (string), exit 0.
#       Convention: lowercase, [a-z0-9_], stable string.
#
#   <name>__discover()
#       → prints TSV lines (one per item):  type\tidentifier\tscope\tpath
#       Fields:
#         type:       backend-specific (e.g. "agent"/"daemon"/"appex")
#         identifier: stable ID (e.g. launchd label, pluginkit bundle ID)
#         scope:      "user" | "gui" | "system" (LaunchAgents, Helper)
#         path:       absolute path to the definition file
#       Exit 0 = OK (even with 0 items). Non-zero = backend error.
#
#   <name>__block <type> <identifier> <scope> <path>
#       → attempts to block the item.
#       Exit codes:
#         0  = newly blocked
#         1  = already blocked (idempotent skip — analogous to v4.1.1 LOG-1)
#         2  = needs sudo (system scope, daemon cannot escalate)
#         3  = hard failure (validation, missing tool, permission denied)
#         99 = test guard fired (REAL_DENY)
#
#   <name>__allow <type> <identifier> <scope> <path>
#       → attempts to re-enable the item.
#       Exit codes:
#         0 = re-enabled
#         1 = not in disabled state (no-op)
#         2 = needs sudo
#         3 = hard failure
#
#   <name>__is_blocked <type> <identifier> <scope> <path>
#       → checks the block state.
#       Exit codes:
#         0 = blocked
#         1 = not blocked
#         2 = unknown (e.g. missing privileges to check)
#
#   <name>__kill_running()
#       → kills running processes belonging to this backend.
#       Optional — backends without their own processes (e.g. pluginkit
#       definitions that are purely static) implement this as a no-op with
#       return 0.
#       Exit 0 = OK (even if no processes were running).
#
# === Conformance check ===
# backend_register automatically verifies during the source step that all 6
# functions exist. If one is missing, registration fails with a clear error
# message.
#
# === Function namespacing ===
# The global zsh namespace is flat — backends MUST prefix their functions with
# `<backend_name>__`, otherwise collisions occur. Backend-private helpers
# (not part of the interface) use `_<backend_name>__` (an extra underscore).

# This file contains documentation only — no executable code, no source guard.
# It is NOT loaded by the main script (pure reference for backend authors).
:
