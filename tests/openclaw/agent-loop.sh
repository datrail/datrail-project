#!/bin/sh
# The agent: OpenClaw turns against the stub model, each followed by a pause
# of TURN_INTERVAL seconds, keeping its state between turns as a
# long-running agent does. A failed turn is logged and the loop goes on.
#
# OPENCLAW_FORM picks how OpenClaw runs:
#   exec     its CLI, one `openclaw agent exec` process per turn;
#   gateway  its long-running gateway (`openclaw gateway run`, listening on
#            all interfaces as a gateway in a container is), with each turn
#            sent to it by `openclaw agent --message`. The gateway makes
#            every model call itself, over connections it keeps across
#            turns (railmon#70 and #97 came from this form).
set -u
mkdir -p "$HOME/work" "$HOME/state"
form="${OPENCLAW_FORM:-exec}"
case "$form" in
  exec) ;;
  gateway)
    # The gateway writes beside its config, so the config goes in its home.
    # The token only guards this container's own gateway.
    mkdir -p "$HOME/.openclaw"
    cp /opt/openclaw-ci/openclaw-gateway.json "$HOME/.openclaw/openclaw.json"
    OPENCLAW_GATEWAY_TOKEN=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    export OPENCLAW_GATEWAY_TOKEN
    openclaw gateway run > /tmp/gateway.log 2>&1 &
    gateway=$!
    ready=""
    for _ in $(seq 120); do
      openclaw gateway health > /dev/null 2>&1 && { ready=1; break; }
      kill -0 "$gateway" 2> /dev/null || break
      sleep 1
    done
    [ -n "$ready" ] || { echo "the gateway never answered: $(tail -c 2000 /tmp/gateway.log)"; exit 1; }
    echo "gateway up (pid $gateway)"
    ;;
  *) echo "OPENCLAW_FORM must be exec or gateway, not $form"; exit 2 ;;
esac
turn=0
while :; do
  turn=$((turn + 1))
  prompt="Turn $turn: save the note the model asks for."
  if [ "$form" = gateway ]; then
    kill -0 "$gateway" 2> /dev/null \
      || { echo "the gateway exited: $(tail -c 2000 /tmp/gateway.log)"; exit 1; }
    set -- openclaw agent --agent main --json --timeout 120 --message "$prompt"
  else
    set -- openclaw agent exec --config /opt/openclaw-ci/openclaw.json --model stub/stub-1 \
      --cwd "$HOME/work" --state-dir "$HOME/state" --json --timeout 120 "$prompt"
  fi
  if "$@" > /tmp/turn.json 2> /tmp/turn.err; then
    echo "turn $turn: $(grep -c '"write"' /tmp/turn.json) write tool mention(s)"
  else
    echo "turn $turn failed: $(tail -c 2000 /tmp/turn.err)"
  fi
  sleep "${TURN_INTERVAL:-10}"
done
