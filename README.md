# 3-Layer Security Pipeline for Kubernetes (K3s)

A **Defense-in-Depth** security architecture for automated application deployment on a lightweight Kubernetes (K3s) cluster, coordinating three industry-standard tools across different lifecycle stages:

- **Trivy** — Pre-deployment static image analysis
- **Calico** — Network isolation / Zero-Trust architecture
- **Falco** — Real-time runtime threat detection

---

## Directory Structure

```
📦 K8s-DevSecOps-Project
 ┣ 📂 docs
 ┃ ┗ 📜 security-report.md
 ┣ 📂 images
 ┃ ┣ 🖼️ trivy-scan.png
 ┃ ┣ 🖼️ calico-ping-fail.png
 ┃ ┗ 🖼️ falco-alert.png
 ┣ 📂 manifests
 ┃ ┗ 📜 block-all.yaml
 ┣ 📂 scripts
 ┃ ┗ 📜 deploy-pipeline.sh
 ┗ 📜 README.md
```

---

## 1. Architecture Overview

The pipeline ensures no application can be deployed or communicate within the cluster without passing through all security gates:

1. **Trivy (Static Security):** Scans container images during CI/CD. Automatically aborts deployment if any `CRITICAL` vulnerability is detected.
2. **Calico (Network Security):** Dynamically applies micro-segmentation network policies based on application tiers (`web`, `backend`, `database`), enforcing strict least-privilege communication.
3. **Falco (Runtime Security):** Continuously monitors the active cluster at the Linux kernel level via eBPF probes, capturing unauthorized actions (e.g., shell spawns, sensitive file access) in real time.

### Pipeline Flow

```
[Input Image] ──> [Stage 1: Trivy Scan] ──> FAIL ──> [Block Deployment]
                          │
                         PASS
                          ▼
               [Stage 2: kubectl apply] ──> Label tier (web / backend / db)
                          │
                          ▼
               [Stage 3: Calico Policy] ──> Generate dynamic YAML ──> Done
```

---

## 2. Prerequisites & Environment Setup

### Environment Details

| Component | Details |
|---|---|
| Orchestrator | K3s (Lightweight Kubernetes) |
| Container Runtime | Containerd (custom K3s paths) |
| OS / Node | Ubuntu Server 22.04 LTS |

### Component Configurations

- **Calico CNI:** Installed as the core network provider, replacing the default Flannel CNI to support advanced `NetworkPolicy` custom resources.
- **Falco Driver:** Configured with the modern eBPF probe, pointing to the non-standard K3s container runtime socket:

```bash
--set mounts.nodes.paths="{/run/k3s/containerd/containerd.sock}"
```

---

## 3. Automated Deployment Pipeline

The deployment process is managed via an interactive shell script (`deploy-pipeline.sh`) that mimics a CI/CD engine.

### Stage 1 — Trivy Scan

- Scans the target image for known security vulnerabilities (CVEs).
- **FAIL** → Pipeline exits immediately; deployment is blocked.
- **PASS** → Proceeds to Stage 2.

### Stage 2 — kubectl apply

- Deploys the workload onto the cluster.
- Attaches a `tier` label to each resource: `web`, `backend`, or `db`.

### Stage 3 — Calico Policy

- Automatically generates a `NetworkPolicy` YAML based on the assigned `tier` label.
- Applies the policy to enforce Zero-Trust micro-segmentation.

### Usage

```bash
./deploy-pipeline.sh <image-name>
```

---

## 4. Validation Scenarios

### Scenario 1: Pre-deployment Image Scanning (Trivy Gate)

**Test A — Insecure image (expected: blocked)**

```bash
./deploy-pipeline.sh nginx:1.14
```

> **Expected:** Trivy detects multiple `CRITICAL` vulnerabilities. The pipeline exits with code `1` and halts before reaching the cluster.

**Test B — Secure image (expected: pass)**

```bash
./deploy-pipeline.sh nginx:alpine
```

> **Expected:** No `CRITICAL` findings. The pipeline proceeds to Stage 2.

---

### Scenario 2: Zero-Trust Network Micro-segmentation (Calico Gate)

The cluster enforces strict tier separation inside the `production-env` namespace across three workloads: `web-app`, `backend-app`, and `database-app`.

```bash
# Retrieve pod IPs for testing
kubectl get pods -n production-env -o wide
```

**Test A — Allowed traffic (web → backend)**

```bash
kubectl exec -it web-app -n production-env -- ping -c 4 <BACKEND_POD_IP>
```

> **Expected:** ICMP packets transmit successfully.

**Test B — Blocked traffic (web → database)**

```bash
kubectl exec -it web-app -n production-env -- ping -c 4 <DATABASE_POD_IP>
```

> **Expected:** Connection drops completely — persistent request timeout with no response.

---

### Scenario 3: Real-time Incident Detection (Falco Gate)

Even if an attacker gains access inside a running container, all actions are tracked in real time at the kernel level.

**Simulate a malicious shell session:**

```bash
kubectl exec -it backend-app -n production-env -- /bin/bash
cat /etc/shadow
exit
```

**Verify Falco alerts:**

```bash
kubectl logs <falco-pod-name> -n falco -c falco | grep -E "Notice|Warning"
```

> **Expected:** Falco captures `execve` and `openat` syscalls and outputs structured alerts containing full container metadata (pod name, namespace, image, process tree).

---

## 5. Technical Challenges & Lessons Learned

### 1. K3s Non-standard Container Runtime Socket

Falco suffered from **container blindness** because K3s isolates its runtime socket at `/run/k3s/containerd/containerd.sock` instead of the standard path `/run/containerd/containerd.sock`.

**Fix:** Manually override the Helm chart mount paths to restore container mapping visibility.

### 2. Missing Kubeconfig for Third-party Tools

Automating deployments via Helm triggered connection timeouts on port `8080` due to missing cluster credentials.

**Fix:** Explicitly export the `KUBECONFIG` environment variable pointing to `/etc/rancher/k3s/k3s.yaml`.

### 3. Kernel Header Dependencies

Runtime monitoring via eBPF requires direct kernel symbol mapping, which depends on the presence of matching kernel headers.

**Fix:** Manually install `linux-headers` packages that match the active kernel version before loading the eBPF driver.
