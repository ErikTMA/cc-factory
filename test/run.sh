#!/bin/sh
# Run every offline harness (Lua 5.2, like CC's Cobalt) in Docker.
# Each suite runs in seconds; one that takes over LIMIT seconds is stuck in a
# loop and fails as such.
# Usage: test/run.sh   (from the repo root)
set -e
cd "$(dirname "$0")/.."
LIMIT=${LIMIT:-60}
docker run --rm -e LIMIT=$LIMIT -v "$PWD":/w -w /w/test nickblah/lua:5.2 sh -c '
  set -e
  for f in ../*.lua; do luac -p "$f"; done
  suite() {
    name=$1; shift
    echo "== $name"
    set +e
    out=$(timeout "$LIMIT" lua "$@" 2>&1); rc=$?
    set -e
    if [ $rc -eq 124 ] || [ $rc -eq 143 ]; then echo "STUCK: over $LIMIT s (1 FAILURE)"; else echo "$out" | tail -1; fi
  }
  suite "miner + base dispatcher" sim.lua ../oreminer.lua
  suite "forester"                forester_sim.lua ../forester.lua
  suite "base boots"              base_sim.lua ..
  suite "whole factory"           factory_sim.lua ..
' | tee /dev/stderr | grep -q "FAILURE" && exit 1 || exit 0
