#!/bin/bash
# run-plenary.sh — run a plenary spec directory and reap hung children.
#
# Usage: scripts/run-plenary.sh <init.lua> <spec-dir>
#
# PlenaryBustedDirectory spawns one child headless nvim per spec file and never
# reaps children that outlive the parent, so a hung spec leaks an orphaned
# "plenary.busted" nvim. Run the parent under job control so it leads its own
# process group, then SIGKILL whatever is left in that group after it exits
# (a child wedged in Lua never services SIGTERM). Concurrent plenary runs live
# in other process groups and are untouched. stdin comes from /dev/null so the
# backgrounded nvim can't be stopped by SIGTTIN when run from a terminal.

set -u

init=$1
dir=$2

set -m
nvim --headless -u "$init" \
  -c "PlenaryBustedDirectory $dir { minimal_init = '$init' }" </dev/null &
pid=$!
trap 'pkill -KILL -g "$pid" 2>/dev/null' INT TERM
wait "$pid"
st=$?
pkill -KILL -g "$pid" 2>/dev/null
exit "$st"
