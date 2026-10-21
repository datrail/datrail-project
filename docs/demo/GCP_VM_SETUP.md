# A throwaway GCP VM for datRail

Why a VM: RailMon's probes need a Linux kernel with BTF and privileged containers in the host PID namespace. A Mac only watches agents inside Docker Desktop's VM; OpenShell only ships a Linux .deb. A small GCP VM gives both and costs about $0.13 an hour while it runs.

## What I built

| Item | Value |
| --- | --- |
| Project / zone | `<your-project>`, `us-east1-b` (any project you have Compute Admin on works) |
| Machine | `e2-standard-4` (4 vCPU, 16 GB), Ubuntu 24.04 LTS (`ubuntu-2404-lts-amd64`), 50 GB pd-balanced |
| Network | no external IP (org policy `compute.vmExternalIpAccess` forbids it): SSH through IAP, outbound through a Cloud NAT |
| Kernel | 7.0.0-1011-gcp, BTF present (`/sys/kernel/btf/vmlinux`) |
| Docker | Engine 29.9, Compose v5.6, from Docker's apt repo |

## 1. Create it (once)

```bash
gcloud auth login
gcloud compute instances create datrail-demo --project <your-project> --zone us-east1-b \
  --machine-type e2-standard-4 --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
  --boot-disk-size 50GB --boot-disk-type pd-balanced --no-address --metadata enable-oslogin=TRUE \
  --labels purpose=datrail-integration-test,owner=<you>
```

Once per region, so the VM can reach GitHub, ghcr and apt without an external IP:

```bash
gcloud compute routers create datrail-demo-router --project <your-project> --region us-east1 --network default
gcloud compute routers nats create datrail-demo-nat --project <your-project> --region us-east1 --router datrail-demo-router \
  --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
```

Rename `datrail-demo-...` to yours. The NAT gateway bills about $1 a day while it exists; delete it with the VM.

## 2. Log in (IAP tunnel, with RailDash forwarded to your laptop)

```bash
gcloud compute ssh datrail-demo --project <your-project> --zone us-east1-b --tunnel-through-iap -- -L 8000:127.0.0.1:8000
```

Then the VM's RailDash is http://127.0.0.1:8000 on your laptop. The first SSH right after boot can fail with code 255; wait 15 s and retry. The tunnel dies when the session ends, so keep that terminal open while you demo.

## 3. Bootstrap (once, on the VM, about 3 minutes)

```bash
sudo apt-get update -qq && sudo apt-get install -y -qq ca-certificates curl git make jq
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -qq && sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"
sudo loginctl enable-linger "$USER"
```

Log out and back in so the docker group applies. Check: `ls /sys/kernel/btf/vmlinux`, `docker run --rm --privileged hello-world`.

`enable-linger` is what lets OpenShell's gateway (a user-level systemd service) survive the SSH session ending; without it, mode C dies when you log out.

## 4. datRail

```bash
git clone https://github.com/datrail/datrail-project.git && cd datrail-project
docker compose up -d            # first build from master: about 5 minutes on this machine
```

Then the runbook (`DEMO_RUNBOOK.md`): Part A on the demo agent, Part C after `bash tests/openshell/install.sh` (OpenShell 0.1.3, Docker driver). The CI script also runs here as is: `STACK_MODE=demo|own-agent|openshell make test` (7 to 8 minutes each), and the image-only install as `RAILMON_IMAGE=ghcr.io/datrail/railmon:0.1.0-m4 STACK_MODE=demo make test`.

Known hiccup: if a nested build dies with `curl: (35) Connection reset`, the Docker bridge MTU is above the host's; `docker build --network host` for railmon gets past it (I did not hit it on this VM).

## 5. Stop, start, delete

```bash
gcloud compute instances stop datrail-demo --project <your-project> --zone us-east1-b     # ~$2/month for the disk while stopped
gcloud compute instances start datrail-demo --project <your-project> --zone us-east1-b    # 40 s, then SSH as in step 2
gcloud compute instances delete datrail-demo --project <your-project> --zone us-east1-b
gcloud compute routers nats delete datrail-demo-nat --router datrail-demo-router --region us-east1 --project <your-project>
gcloud compute routers delete datrail-demo-router --region us-east1 --project <your-project>
```

