#!/bin/sh
# The agent: one OpenClaw turn every TURN_INTERVAL seconds, against the stub
# model, keeping its state between turns as a long-running agent does. A
# failed turn is logged and the loop goes on.
set -u
mkdir -p "$HOME/work" "$HOME/state"
turn=0
while :; do
  turn=$((turn + 1))
  if openclaw agent exec --config /opt/openclaw-ci/openclaw.json --model stub/stub-1 \
      --cwd "$HOME/work" --state-dir "$HOME/state" --json --timeout 120 \
      "Turn $turn: save the note the model asks for." > /tmp/turn.json 2> /tmp/turn.err; then
    echo "turn $turn: $(grep -c '"write"' /tmp/turn.json) write tool mention(s)"
  else
    echo "turn $turn failed: $(tail -c 2000 /tmp/turn.err)"
  fi
  sleep "${TURN_INTERVAL:-10}"
done
