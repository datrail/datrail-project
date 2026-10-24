#!/usr/bin/env bash
# Record what the pinned OpenShell prints about a sandbox's policy and its
# denials, as fixtures for RailDash's policy import and RailMon's collector
# (DR-248, DR-249). Needs OpenShell's gateway running (install.sh). Writes
# one directory per case under $1: the `--policy-only` YAML a user uploads,
# the JSON views, the revision list, and every command's stderr. A failing
# command is recorded, not fatal: a refusal is a fixture too.
set -uo pipefail
out=${1:?usage: record-fixtures.sh <output dir>}
here=$(cd "$(dirname "$0")/fixtures" && pwd)
mkdir -p "$out"
export NO_COLOR=1
# Not a credential: a marker whose absence from every output is checked.
marker=fixture-credential-must-not-appear

run() {  # run <case> <name> <command...>: stdout to <name>, stderr beside it
  local dir="$out/$1" name=$2; shift 2
  mkdir -p "$dir"
  "$@" > "$dir/$name" 2> "$dir/$name.stderr"
  echo "$?" > "$dir/$name.exit"
}
wait_ready() {
  for _ in $(seq 90); do
    phase=$(openshell sandbox get "$1" 2>/dev/null | sed -n 's/^ *Phase: *//p')
    [[ $phase == Ready ]] && return 0
    sleep 2
  done
  echo "sandbox $1 not Ready (phase '${phase:-}')" >&2
  return 1
}
record() {  # record <case> <sandbox>: every view of its policy
  run "$1" sandbox-get.txt openshell sandbox get "$2"
  run "$1" policy-only.yaml openshell sandbox get "$2" --policy-only
  run "$1" sandbox-get.json openshell sandbox get "$2" -o json
  run "$1" policy-full.json openshell policy get "$2" --full -o json
  run "$1" policy-base.json openshell policy get "$2" --base -o json
  run "$1" policy-list.txt openshell policy list "$2"
}
create() {  # create <case> <sandbox> <args...>
  local case=$1 sb=$2; shift 2
  run "$case" sandbox-create.txt openshell sandbox create --name "$sb" \
    --from datrail-openshell-fixture:local --detach --no-tty "$@" \
    -- sh -c 'sleep 20; python3 /opt/attempts.py; sleep 3600'
  wait_ready "$sb" >> "$out/$case/sandbox-create.txt.stderr" 2>&1
}

openshell --version > "$out/openshell-version.txt" 2>&1
docker build -t datrail-openshell-fixture:local "$here" > "$out/build.log" 2>&1 || exit 1

# The sandbox policy alone, with its denials: one attempt of each kind.
create base fx-base --policy "$here/base.yaml"
record base fx-base
sleep 45
run base logs-sandbox.txt openshell logs fx-base --source sandbox -n 2000
run base logs-all.txt openshell logs fx-base -n 2000
# A revision added by `policy update`, so the list holds two.
run base policy-update.txt openshell policy update fx-base \
  --add-endpoint 'api.openai.com:443:read-only:rest:enforce' \
  --binary /usr/local/bin/python3.13 --wait
run base policy-only-rev2.yaml openshell sandbox get fx-base --policy-only
run base policy-list-rev2.txt openshell policy list fx-base

# Provider rules: one provider that needs no credential, one that holds one.
# A gateway starts with no provider profiles; import the two from the
# pinned release's own examples.
version=$(openshell --version | awk '{print $2}')
for profile in pypi github; do
  run provider "profile-import-$profile.txt" openshell profile import --global \
    --url "https://raw.githubusercontent.com/NVIDIA/OpenShell/v$version/providers/$profile.yaml"
done
run provider provider-create-pypi.txt openshell provider create --name fx-pypi --type pypi
run provider provider-create-github.txt openshell provider create --name fx-github \
  --type github --credential "GITHUB_TOKEN=$marker"
providers=()
grep -q '^0$' "$out/provider/provider-create-pypi.txt.exit" && providers+=(--provider fx-pypi)
grep -q '^0$' "$out/provider/provider-create-github.txt.exit" && providers+=(--provider fx-github)
create provider fx-provider --policy "$here/base.yaml" "${providers[@]}"
record provider fx-provider

create mcp fx-mcp --policy "$here/mcp.yaml"
record mcp fx-mcp

create allowed-ips fx-ips --policy "$here/allowed-ips.yaml"
record allowed-ips fx-ips

# The global policy last: it replaces every sandbox's policy.
run global policy-set-global.txt openshell policy set --global --policy "$here/global.yaml" --yes
sleep 15
record global fx-base
run global policy-get-global.json openshell policy get --global --full -o json
run global policy-list-global.txt openshell policy list --global
run global policy-delete-global.txt openshell policy delete --global --yes

# What a user gets for a sandbox that doesn't exist: an upload of this is
# the commonest parse failure.
run missing policy-only.yaml openshell sandbox get fx-no-such-sandbox --policy-only

for sb in fx-base fx-provider fx-mcp fx-ips; do
  openshell sandbox delete "$sb" > /dev/null 2>&1 || true
done
if grep -rl -- "$marker" "$out" | grep -v 'provider-create-github.txt'; then
  echo "the provider's credential appears in an output above" | tee "$out/CREDENTIAL-LEAK"
fi
echo "recorded under $out"
