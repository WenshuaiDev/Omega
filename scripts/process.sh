#!/usr/bin/env bash
# Bounded direct-child lifecycle shared by thin host wrappers. No task engine.
# CHILD remains visible to the caller's signal trap until the child is reaped.
stop_child() {
  local pid=${1:-} grace=${2:-5} started=$SECONDS
  [ -n "$pid" ] || return 0
  STOP_FORCED=false
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$((SECONDS-started))" -lt "$grace" ]; do sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then STOP_FORCED=true; kill -KILL "$pid" 2>/dev/null || true; fi
  wait "$pid" 2>/dev/null || true
}
bounded() {
  local limit=$1 started=$SECONDS result=0 previous=${CHILD:-}; shift
  "$@" & CHILD=$!
  while kill -0 "$CHILD" 2>/dev/null; do
    if [ "$((SECONDS-started))" -ge "$limit" ]; then
      stop_child "$CHILD" "${BOUND_GRACE:-2}"; CHILD=$previous; return 5
    fi
    sleep 0.1
  done
  wait "$CHILD" || result=$?
  CHILD=$previous
  return "$result"
}
