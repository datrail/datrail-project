# DatRail on a Google Cloud VM, step by step

A first install on a Linux VM in Google Cloud, from creating the VM to seeing drift in RailDash, with the dashboard open in the browser on your own computer. For a PC or a Mac, see [setup-windows.md](setup-windows.md) or [setup-mac.md](setup-mac.md). For every setting and option, see [INSTALL.md](../INSTALL.md).

## What you end up with

Your own VM running DatRail: RailMon watching a demo AI agent, and the RailDash dashboard open in your browser at http://127.0.0.1:8000 through an SSH tunnel.

A VM runs native Linux, so RailMon sees every process on it, not only containers. Use one when your computer can't run the probes itself (a Mac only shows agents inside Docker Desktop), for an agent in an [OpenShell sandbox](../INSTALL.md#an-agent-in-an-openshell-sandbox), which needs native Linux, or to keep the demo off your own machine. Each person gets their own VM, so several people can run the demo at the same time.

The VM has no external IP address. You reach it through Google's IAP tunnel, and it reaches the internet through a Cloud NAT.

## Before you start

- The **Google Cloud CLI** (`gcloud`) on your computer, signed in: `gcloud auth login`. Install it from https://cloud.google.com/sdk/docs/install . On Windows, install it in WSL (Ubuntu), since the script is a bash script.
- A **Google Cloud project** with billing, where you have these roles: Compute Instance Admin (v1), IAP-secured Tunnel User, Compute OS Admin Login, and Service Account User. A project admin can grant them.
- A **Cloud NAT** in the region you use (the default is `us-east1`). Many projects already have one. If not, the script says so and Troubleshooting has the two commands.
- Cost: about $0.13 an hour while the VM runs (`e2-standard-4`, 4 vCPU, 16 GB), and about $2 a month for its 50 GB disk while it is stopped.

Time: about 5 minutes. Creating the VM takes under a minute, Docker installs on it in about 2 minutes, and DatRail starts in under a minute.

## Step 1: Get the VM script

On your computer:

```bash
curl -fsSLO https://raw.githubusercontent.com/datrail/datrail-project/master/gcp-vm.sh
chmod +x gcp-vm.sh
```

`./gcp-vm.sh --help` lists what it does. It runs only `gcloud` commands, on your behalf.

## Step 2: Create the VM

```bash
./gcp-vm.sh create --project YOUR-PROJECT
```

It creates a VM named after your Google account (for `ana@example.com`, `datrail-ana`) in `us-east1-b` (`--name` and `--zone` change those), with Ubuntu 24.04 and no external IP, and it ends with:

```text
Created. Docker installs in the background over the next 2 minutes or so.
```

To skip `--project` every time, set it once: `gcloud config set project YOUR-PROJECT`. The commands below leave it out.

## Step 3: Connect

Wait about 2 minutes for Docker to install, then:

```bash
./gcp-vm.sh ssh
```

The first time, `gcloud` may ask to create an SSH key: press Enter. If the VM is still booting, the script retries every 15 seconds. You are then in a shell on the VM. **Keep this window open while you use RailDash:** the tunnel to the dashboard closes when the session ends.

Check that Docker is ready and the kernel has BTF:

```bash
ls /var/lib/datrail-vm/ready /sys/kernel/btf/vmlinux
```

Both paths are printed. If `ready` is missing, Docker is still installing: wait a minute and try again.

## Step 4: Let your user run Docker

On the VM, once:

```bash
sudo usermod -aG docker $USER
exit
```

Then connect again with `./gcp-vm.sh ssh`, so the change applies. `docker version` now answers without `sudo`.

## Step 5: Install DatRail

On the VM:

```bash
curl -fsSL https://raw.githubusercontent.com/datrail/datrail-project/master/install.sh | bash -s -- --demo --yes
```

It checks the VM, puts DatRail's files in `~/datrail`, downloads the images (about 540 MB) and ends with `DatRail is running`. On an `e2-standard-4` this takes under a minute.

## Step 6: Open the dashboard

In the browser on **your own computer**, open http://127.0.0.1:8000 . The SSH session from Step 3 carries it to the VM.

Within a minute or two you should see:

- **Interactions**: the demo agent's calls to `127.0.0.1:8443`: `POST /v1/demo` and `/v1/demo/other`, and calls to its tool server at `/mcp`. Each call shows twice, once from each side, because the demo agent calls itself.
- **Agent Security Profile alignment**: a profile (ASP) for the demo agent. Click **Inspect evidence** to see its open port 8443 and the files it opened.

That is a working install.

## Step 7: Try the demo

1. **Lock a baseline.** Wait until there are two profiles under "Agent Security Profile alignment" (the second arrives a minute after the first). On the newest one, click **Lock this as your alignment baseline**. The status reads **ALIGNED, v1.0 (active)**.
2. **Make the demo agent open a new port.** On the VM:

   ```bash
   docker exec -d datrail-demo-agent python3 -m http.server 9000 --bind 127.0.0.1
   ```

   Within a minute RailDash shows **DRIFT DETECTED**, and `observed_listeners` has gained port 9000.

The rest of the walk (the Data Guardrail, then breaking it) is in the README, [What you see in RailDash](../README.md#what-you-see-in-raildash).

## Watch an agent you already run

On the VM, run the install without `--demo --yes`, and pick your agent from the list:

```bash
curl -fsSL https://raw.githubusercontent.com/datrail/datrail-project/master/install.sh | bash
```

For an agent that runs directly on the VM rather than in a container, [INSTALL.md, Watch your own agent](../INSTALL.md#watch-your-own-agent) says what DatRail sees of it and how to point it there.

**An agent in an OpenShell sandbox** works here too, since the VM is native Linux. First run `sudo loginctl enable-linger $USER` on the VM, once: OpenShell's gateway is a user-level service, and without it the gateway stops when you disconnect. Then follow [INSTALL.md, An agent in an OpenShell sandbox](../INSTALL.md#an-agent-in-an-openshell-sandbox).

## Stop, start and delete

On your computer:

```bash
./gcp-vm.sh stop      # when you are done; the disk is kept (about $2 a month)
./gcp-vm.sh start     # to use it again, then ./gcp-vm.sh ssh
./gcp-vm.sh delete    # when you no longer need it; deletes the disk too
./gcp-vm.sh status    # whether it exists and is running
```

`delete` asks you to type the VM's name first (`--yes` skips that). The VM carries an `owner` label with your Google account, and `delete` won't delete a VM someone else made.

DatRail starts again by itself when the VM starts, and RailDash keeps its data. On the VM, `cd ~/datrail` and `docker compose down -v` stops it and deletes the data.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| `gcp-vm.sh: the default network has no Cloud NAT in <region>` | The VM couldn't download anything. A project admin creates one, once per region: `gcloud compute routers create datrail-router --region REGION --network default`, then `gcloud compute routers nats create datrail-nat --router datrail-router --region REGION --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges`. It bills about $1 a day. Or use `--zone` in a region that has one. |
| `gcp-vm.sh ssh` keeps failing with code 255 | Right after a start this is the VM booting, and the script retries. If it never connects, check your four roles (Before you start) and that the network allows SSH from IAP's range, `35.235.240.0/20`, on TCP port 22. The default network's `default-allow-ssh` rule does. |
| `permission denied` on `docker` | Step 4 hasn't applied yet: `exit` and connect again. |
| `sudo` asks for a password or is refused | Your account has Compute OS Login but not Compute OS Admin Login. Ask for the admin one (Before you start). |
| `ls: cannot access '/var/lib/datrail-vm/ready'` | Docker is still installing. Wait a minute. If it is still missing after 5 minutes, `sudo journalctl -u google-startup-scripts -n 50` shows why. |
| Port 8000 is already in use on your computer | Connect with another port and install on the same one: `./gcp-vm.sh ssh --port 18000`, then on the VM add `--port 18000` to the install command and open http://127.0.0.1:18000 . |
| The dashboard stopped answering | The SSH session from Step 3 ended. Connect again with `./gcp-vm.sh ssh`. |

More in [INSTALL.md, Troubleshooting](../INSTALL.md#troubleshooting).
