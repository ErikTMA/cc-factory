#!/bin/sh
# Run every offline harness (Lua 5.2, like CC's Cobalt) in Docker.
# Usage: test/run.sh   (from the repo root)
set -e
cd "$(dirname "$0")/.."
docker run --rm -v "$PWD":/w -w /w/test nickblah/lua:5.2 sh -c '
  set -e
  for f in ../*.lua; do luac -p "$f"; done
  echo "== miner + base dispatcher";  lua sim.lua ../oreminer.lua      | tail -1
  echo "== forester";                lua forester_sim.lua ../forester.lua | tail -1
  echo "== base boots";              lua base_sim.lua ..              | tail -1
  echo "== whole factory";           lua factory_sim.lua ..           | tail -1
' | tee /dev/stderr | grep -q "FAILURE" && exit 1 || exit 0
