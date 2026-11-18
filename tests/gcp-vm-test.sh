#!/usr/bin/env bash
# gcp-vm.sh ssh without Google Cloud: a stand-in `gcloud` on PATH answers what
# gcp-vm.sh asks and keeps the script it would run on the VM. That script is then
# run here against stand-in `id`, `sudo` and `sleep`, with the VM's ready marker
# and Docker socket moved into a temporary directory: waiting for Docker, the
# docker group, and the shell at the end. Seconds, on any host.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/vm"
export FAKE_LOG="$work/log" FAKE_SESSION="$work/session" FAKE_TRIES="$work/tries" \
  FAKE_GROUPS_DB="$work/groups" FAKE_VM="$work/vm"
# A home without gcloud's SSH key unless a case makes one, and no verbosity of
# the caller's own.
export HOME="$work/home"
unset CLOUDSDK_CORE_VERBOSITY
mkdir -p "$HOME/.ssh"

cat > "$work/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
# The stand-in: FAKE_STATUS is the VM's status, FAKE_SSH_FAILS how many
# connections fail with 255 before one works. The session script is kept in
# FAKE_SESSION and logged as <session>, and gcloud's verbosity, when set, as
# [verbosity=...]. FAKE_OWNER is the VM's owner label (ana's own by default;
# empty for a VM without one).
args=() session=
while [ $# -gt 0 ]; do
  if [ "$1" = --command ]; then session=$2; args+=(--command "<session>"); shift 2
  else args+=("$1"); shift; fi
done
echo "gcloud ${args[*]}${CLOUDSDK_CORE_VERBOSITY:+ [verbosity=$CLOUDSDK_CORE_VERBOSITY]}" >> "$FAKE_LOG"
case "${args[*]}" in
  "config get-value project") echo my-project ;;
  "config get-value account") echo ana@example.com ;;
  "compute instances describe "*"--format=value(status)") echo "${FAKE_STATUS:-}" ;;
  "compute instances describe "*"--format=value(labels.owner)") echo "${FAKE_OWNER-ana-example-com}" ;;
  "compute ssh "*)
    printf '%s' "$session" > "$FAKE_SESSION"
    n=$(( $(cat "$FAKE_TRIES" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_TRIES"
    [ "$n" -gt "${FAKE_SSH_FAILS:-0}" ] || exit 255 ;;
  *) echo "fake gcloud: unexpected: ${args[*]}" >&2; exit 99 ;;
esac
EOF
# `id -nG USER` reads FAKE_GROUPS_DB (what /etc/group says); `id -nG` alone is
# FAKE_GROUPS_NOW (the groups this session started with).
cat > "$work/bin/id" <<'EOF'
#!/usr/bin/env bash
if [ $# -eq 2 ]; then cat "$FAKE_GROUPS_DB"; else echo "${FAKE_GROUPS_NOW:-ana adm}"; fi
EOF
# FAKE_SUDO=no: refused. usermod adds docker to FAKE_GROUPS_DB.
cat > "$work/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$FAKE_LOG"
[ "${FAKE_SUDO:-yes}" = yes ] || { echo "sudo: a password is required" >&2; exit 1; }
case "$*" in
  "-n usermod -aG docker ana") echo "ana adm docker" > "$FAKE_GROUPS_DB" ;;
  "-n -i -u ana") echo "a new login shell, groups: $(cat "$FAKE_GROUPS_DB")" ;;
esac
EOF
# Docker finishes installing after FAKE_READY_AFTER sleeps (never if unset).
cat > "$work/bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "sleep $*" >> "$FAKE_LOG"
n=$(( $(grep -c '^sleep' "$FAKE_LOG") ))
if [ -n "${FAKE_READY_AFTER:-}" ] && [ "$n" -ge "$FAKE_READY_AFTER" ]; then touch "$FAKE_VM/ready"; fi
EOF
cat > "$work/bin/login-shell" <<'EOF'
#!/usr/bin/env bash
echo "the login shell ($*)"
EOF
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"
fails=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; sed 's/^/      | /' "$work/out"; fails=$((fails + 1)); }
has() { grep -qF -- "$2" "$1"; }

# vmside: run the kept session script as user ana, with the marker and the
# socket in $FAKE_VM.
vmside() {
  : > "$FAKE_LOG"
  sed -e "s|/var/lib/datrail-vm/ready|$FAKE_VM/ready|" -e "s|/var/run/docker.sock|$FAKE_VM/docker.sock|" \
    "$FAKE_SESSION" > "$work/session.sh"
  USER=ana SHELL="$work/bin/login-shell" bash "$work/session.sh" > "$work/out" 2>&1
}
reset_vm() { rm -f "$FAKE_VM"/*; echo "${1:-ana adm}" > "$FAKE_GROUPS_DB"; unset FAKE_READY_AFTER FAKE_SUDO; }

# 1. ssh on a running VM: one connection, through IAP, RailDash's port
# forwarded, the session script as its command.
: > "$FAKE_LOG"; rm -f "$FAKE_TRIES"
if FAKE_STATUS=RUNNING bash "$here/gcp-vm.sh" ssh < /dev/null > "$work/out" 2>&1 \
  && grep -qx -- "gcloud compute ssh datrail-ana --project my-project --zone us-east1-b --tunnel-through-iap --command <session> -- -o LogLevel=ERROR -L 8000:127.0.0.1:8000" "$FAKE_LOG" \
  && [[ $(grep -c '^gcloud compute ssh' "$FAKE_LOG") == 1 ]] && has "$FAKE_SESSION" /var/lib/datrail-vm/ready; then
  ok "ssh: one connection with the session script"
else bad "ssh: one connection with the session script"; fi

# 2. Still booting: 255 twice, then it connects.
: > "$FAKE_LOG"; rm -f "$FAKE_TRIES"
if FAKE_STATUS=RUNNING FAKE_SSH_FAILS=2 bash "$here/gcp-vm.sh" ssh < /dev/null > "$work/out" 2>&1 \
  && [[ $(grep -c '^gcloud compute ssh' "$FAKE_LOG") == 3 ]] && grep -q "Trying again in 15 seconds (2 of 6)" "$work/out"; then
  ok "ssh: retries while the VM boots"
else bad "ssh: retries while the VM boots"; fi

# 3. A stopped VM: no connection.
: > "$FAKE_LOG"
if FAKE_STATUS=TERMINATED bash "$here/gcp-vm.sh" ssh < /dev/null > "$work/out" 2>&1; then
  bad "ssh: a stopped VM"
elif grep -q "is stopped. Start it: gcp-vm.sh start" "$work/out" && ! has "$FAKE_LOG" "compute ssh"; then
  ok "ssh: a stopped VM"
else bad "ssh: a stopped VM"; fi

# 4. On the VM, Docker ready and already in the group: straight to the shell,
# no sudo, nothing printed.
reset_vm "ana adm docker"; touch "$FAKE_VM/ready"
if FAKE_GROUPS_NOW="ana adm docker" vmside && [[ $(cat "$work/out") == "the login shell (-l)" ]] \
  && ! has "$FAKE_LOG" sudo; then
  ok "vm: ready, already in the docker group"
else bad "vm: ready, already in the docker group"; fi

# 5. Ready, first connection: added to the group, then a login shell that has it.
reset_vm; touch "$FAKE_VM/ready"
if vmside && has "$FAKE_LOG" "sudo -n usermod -aG docker ana" && has "$work/out" "Added ana to the docker group" \
  && has "$work/out" "a new login shell, groups: ana adm docker" && ! has "$work/out" "Docker is still installing"; then
  ok "vm: first connection joins the docker group, no reconnect"
else bad "vm: first connection joins the docker group, no reconnect"; fi

# 6. Connected right after create: it says so, waits, then the same.
reset_vm
if FAKE_READY_AFTER=3 vmside && has "$work/out" "Docker is still installing on the VM" \
  && has "$work/out" "Docker is ready." && [[ $(grep -c '^sleep 5' "$FAKE_LOG") == 3 ]] \
  && has "$FAKE_LOG" "sudo -n usermod -aG docker ana" && has "$work/out" "a new login shell"; then
  ok "vm: waits for Docker"
else bad "vm: waits for Docker"; fi

# 7. A VM this script didn't make: Docker's socket is ready enough.
reset_vm
if python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$FAKE_VM/docker.sock" \
  && vmside && ! has "$work/out" "still installing" && has "$FAKE_LOG" "sudo -n usermod -aG docker ana"; then
  ok "vm: Docker's socket without the marker"
else bad "vm: Docker's socket without the marker"; fi

# 8. Docker never finishes: 5 minutes, the log to read, then a shell anyway,
# and no group change for a group that may not exist.
reset_vm
if vmside && [[ $(grep -c '^sleep 5' "$FAKE_LOG") == 60 ]] && has "$work/out" "Still installing, 4 min so far" \
  && has "$work/out" "sudo journalctl -u google-startup-scripts -n 50" && has "$work/out" "the login shell (-l)" \
  && ! has "$FAKE_LOG" usermod; then
  ok "vm: gives up after 5 minutes, shell anyway"
else bad "vm: gives up after 5 minutes, shell anyway"; fi

# 9. sudo refused: it says which role is missing, and the shell still opens.
reset_vm; touch "$FAKE_VM/ready"
if FAKE_SUDO=no vmside && has "$work/out" "Compute OS Admin Login" && has "$work/out" "the login shell (-l)"; then
  ok "vm: sudo refused"
else bad "vm: sudo refused"; fi

# 10. A VM someone else made: it says so, and on the VM the shell opens with no
# change to the docker group.
: > "$FAKE_LOG"; rm -f "$FAKE_TRIES"
if FAKE_STATUS=RUNNING FAKE_OWNER=bo-example-com bash "$here/gcp-vm.sh" ssh < /dev/null > "$work/out" 2>&1 \
  && has "$work/out" "Someone else made datrail-ana (bo-example-com), so this won't add you to its docker group." \
  && [[ $(head -1 "$FAKE_SESSION") == "join_group=no" ]] \
  && reset_vm && touch "$FAKE_VM/ready" && vmside && [[ $(cat "$work/out") == "the login shell (-l)" ]] \
  && ! has "$FAKE_LOG" sudo; then
  ok "ssh: someone else's VM, docker group left alone"
else bad "ssh: someone else's VM, docker group left alone"; fi

# 11. A VM without an owner label (not made by this script): your own to set up.
: > "$FAKE_LOG"; rm -f "$FAKE_TRIES"
if FAKE_STATUS=RUNNING FAKE_OWNER='' bash "$here/gcp-vm.sh" ssh < /dev/null > "$work/out" 2>&1 \
  && ! has "$work/out" "Someone else made" && ! has "$FAKE_SESSION" "join_group=no" \
  && reset_vm && touch "$FAKE_VM/ready" && vmside && has "$FAKE_LOG" "sudo -n usermod -aG docker ana"; then
  ok "ssh: a VM without an owner label joins the docker group"
else bad "ssh: a VM without an owner label joins the docker group"; fi

# 12. Once gcloud's SSH key exists, its warnings are left out (the NumPy one
# on every connection); before that they stay, to explain the key prompt.
: > "$FAKE_LOG"; rm -f "$FAKE_TRIES"
touch "$HOME/.ssh/google_compute_engine"
if FAKE_STATUS=RUNNING bash "$here/gcp-vm.sh" ssh < /dev/null > "$work/out" 2>&1 \
  && grep -q '^gcloud compute ssh .* -- -o LogLevel=ERROR -L 8000:127.0.0.1:8000 \[verbosity=error\]$' "$FAKE_LOG"; then
  ok "ssh: gcloud's warnings left out once its key exists"
else bad "ssh: gcloud's warnings left out once its key exists"; fi
: > "$FAKE_LOG"; rm -f "$FAKE_TRIES"
if FAKE_STATUS=RUNNING CLOUDSDK_CORE_VERBOSITY=debug bash "$here/gcp-vm.sh" ssh < /dev/null > "$work/out" 2>&1 \
  && grep -q '^gcloud compute ssh .* \[verbosity=debug\]$' "$FAKE_LOG"; then
  ok "ssh: a verbosity you set yourself stands"
else bad "ssh: a verbosity you set yourself stands"; fi
rm -f "$HOME/.ssh/google_compute_engine"

[[ $fails == 0 ]] || { echo "$fails case(s) failed"; exit 1; }
echo "all cases passed"
