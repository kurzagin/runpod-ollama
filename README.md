# RunPod Ollama + Caddy TLS Direct Reverse Proxy

A production-ready, reproducible Docker setup for running [Ollama](https://ollama.com/) with any Ollama-compatible LLM (e.g., `llama3.1:8b`, `qwen2.5:14b`, `qwen2.5:32b`) on RunPod GPU Pods.

---

## 1. Architecture & The Privacy Requirement

### The Core Problem with Default RunPod Deployments
Standard RunPod deployments often route requests through RunPod's HTTP proxy (`https://<pod-id>-<port>.proxy.runpod.net`). When using RunPod's HTTP proxy:
* Plaintext HTTP headers and request/response payloads pass through RunPod's reverse proxy infrastructure.
* Intermediary proxies can inspect prompt contents and model completions.
* Aggressive proxy connection timeouts can terminate long-running or streaming LLM generations.
* Random internet traffic can hit unauthenticated endpoints if Ollama is directly bound to public ports.

### The Solution: Direct TCP Forwarding + In-Pod TLS Termination
In this project, **RunPod's HTTP proxy is completely eliminated from the request path**. We use direct **TCP port forwarding** to route encrypted traffic straight to Caddy running **inside** your Pod:

```text
External App / Client
       │
       │ HTTPS / TLS (Encrypted payload across public internet)
       ▼
RunPod Public TCP Port (e.g., 69.164.x.x:19842)
       │
       │ Direct TCP Stream (Raw encrypted bytes forwarded; RunPod HTTP Proxy bypassed)
       ▼
Container Port 8443 (Caddy Reverse Proxy INSIDE the Pod)
       │
       ├── 1. Terminates TLS inside the container
       ├── 2. Enforces Bearer Token Authentication (Authorization: Bearer <API_KEY>)
       ├── 3. Streams requests/responses without proxy buffering
       │
       ▼ Localhost HTTP (127.0.0.1:11434 strictly)
Ollama Server (Listens only on 127.0.0.1; never bound to 0.0.0.0)
       │
       ▼
GPU Execution (VRAM)
       ▲
       │ Weights & manifests
Network Volume (/root/.ollama)
```

### Privacy & Threat Model Guarantees

| Security Property | Guarantee |
| :--- | :--- |
| **RunPod HTTP Proxy** | **NOT used**. Connections bypass the HTTP proxy via direct TCP port forwarding. |
| **Network Interception** | **Protected**. TLS terminates only *after* packets enter Caddy inside your Pod. |
| **Cloudflare / Third Parties** | **Zero third-party proxies**. Direct connection from client to your Pod's TCP port. |
| **Ollama Isolation** | `127.0.0.1:11434` is bound to the loopback interface. It cannot be reached directly from the network. |
| **Access Control** | Caddy immediately returns `401 Unauthorized` for any request lacking the exact Bearer token. |
| **No Conversation Logging** | Access logs that record request/response bodies, prompts, or completions are disabled. |
| **Cloud Provider Trust Limitation** | *Crucial disclaimer*: In-pod TLS prevents network snooping and proxy interception. However, RunPod controls the underlying physical hypervisor, host kernel, and GPU hardware. Network confidentiality does not protect against a host administrator inspecting Pod RAM or VRAM directly. |

---

## 2. Directory Structure

```text
runpod-ollama/
├── Dockerfile              # Multi-stage build: CUDA Ollama base + Caddy binary
├── docker-compose.yml      # Local testing & reproducible orchestration definition
├── Caddyfile               # Caddy reverse proxy, TLS, SSE streaming, & Bearer auth
├── start.sh                # Container entrypoint & graceful signal supervisor (SIGTERM/SIGINT)
├── healthcheck.sh          # Container health probe (Ollama API, Caddy daemon, model check)
├── .dockerignore           # Excludes local artifacts from image build
├── .env.example            # Configuration reference
├── README.md               # Production deployment & operations guide
└── scripts/
    ├── wait-for-ollama.sh  # Readiness probe waiting for Ollama loopback API
    └── pull-model.sh       # Persistent volume model detector & puller
```

---

## 3. Configuration & Environment Variables

Copy `.env.example` to `.env`:

```bash
cp .env.example .env
```

| Variable | Required | Default | Description |
| :--- | :---: | :--- | :--- |
| `MODEL` | **Yes** | `llama3.1:8b` | Target Ollama model tag to pull/verify on boot. |
| `API_KEY` | **Yes** | *(None)* | Secret token required in `Authorization: Bearer <API_KEY>`. Must not be default. |
| `DOMAIN` | No | *(Empty)* | **MODE A**: Set to your FQDN (e.g. `llm.example.com`) for Let's Encrypt.<br>**MODE B**: Leave empty for self-signed/internal TLS. |
| `HTTPS_PORT` | No | `8443` | Internal container port on which Caddy listens for HTTPS. |
| `ACME_EMAIL` | No | `admin@example.com` | Notification email for Let's Encrypt certificate renewals (MODE A only). |
| `OLLAMA_HOST` | No | `127.0.0.1:11434` | Internal bind address for Ollama (must remain localhost). |
| `OLLAMA_KEEP_ALIVE` | No | `30m` | Time to keep model weights loaded in GPU VRAM after idle. |

---

## 4. TLS & Domain Modes

Owning a domain is **not** required. The system automatically detects whether a domain is configured and selects the appropriate mode:

### MODE A — Domain Mode (Publicly Trusted TLS)
* **When to use**: If you own a domain (e.g. `llm.example.com`) and have standard HTTPS port routing.
* **How it works**: Caddy issues a Let's Encrypt / ZeroSSL certificate via ACME.
* **Requirements & Caveats**:
  1. Set `DOMAIN=llm.example.com` in environment variables.
  2. In your DNS provider, point an **A Record** to the RunPod Pod's public IP address with proxying disabled (DNS-only).
  3. *Important ACME Note*: Standard Let's Encrypt validation requires ports `80` or `443`. Because RunPod typically maps high ports (e.g. `:19842`), standard ACME HTTP validation may fail unless your external ingress routes directly to port 443 or you use DNS-01 challenges. For typical RunPod port mappings, **MODE B is recommended**.

### MODE B — No Domain Mode (Self-Signed / Internal TLS)
* **When to use**: If you do not own a domain or want zero external DNS setup.
* **How it works**: Leave `DOMAIN` empty or unset. `start.sh` automatically configures Caddy to use `tls internal`. Caddy generates an in-memory, self-signed TLS certificate.
* **Client Trust Instructions**:
  Traffic remains completely encrypted across the network, but because the certificate is self-signed:
  * **cURL**: Pass `-k` or `--insecure` to encrypt traffic without verifying against public WebPKI roots:
    ```bash
    curl -k https://<RUNPOD_IP>:<MAPPED_PORT>/v1/models -H "Authorization: Bearer $API_KEY"
    ```
  * **Python / OpenAI SDK**: Set `verify=False` or pass `httpx.Client(verify=False)`:
    ```python
    import httpx
    from openai import OpenAI

    client = OpenAI(
        base_url="https://<RUNPOD_IP>:<MAPPED_PORT>/v1",
        api_key="your-api-key",
        http_client=httpx.Client(verify=False),
    )
    ```

---

## 5. Docker Build & Registry Push (GHCR / Docker Hub)
 
You can push to **GitHub Container Registry (`ghcr.io`)** or **Docker Hub**. Repositories can be public or **100% private**.
 
### Option A: GitHub Container Registry (`ghcr.io`) — Recommended
 
```bash
# 1. Authenticate with GitHub Personal Access Token (PAT with write:packages, read:packages)
echo $GH_PAT | docker login ghcr.io -u <YOUR_GITHUB_USERNAME> --password-stdin
 
# 2. Build the image
docker build -t ghcr.io/<YOUR_GITHUB_USERNAME>/runpod-ollama:latest .
 
# 3. Push to GHCR
docker push ghcr.io/<YOUR_GITHUB_USERNAME>/runpod-ollama:latest
```
 
### Option B: Docker Hub
 
```bash
# 1. Log in to Docker Hub
docker login
 
# 2. Build and push
docker build -t <YOUR_DOCKERHUB_USERNAME>/runpod-ollama:latest .
docker push <YOUR_DOCKERHUB_USERNAME>/runpod-ollama:latest
```
 
> [!NOTE]
> **Using a Private Image on RunPod**:
> If your image repository is private, add your registry credentials in the RunPod Console before deploying:
> **User Settings** → **Container Registries** → **+ Add Credentials** (`ghcr.io` or `docker.io`). RunPod will authenticate automatically when pulling the image.

---

## 6. RunPod Deployment Guide (Step-by-Step)

### Step 1: Create a Persistent Network Volume
1. Open the **RunPod Console** -> **Storage** -> **Network Volumes**.
2. Click **+ Network Volume**.
3. Choose a Data Center (e.g., `US-NJ-1` or `EU-RO-1`) and set size (e.g., 50GB–100GB).
4. Name the volume `ollama-storage`.

### Step 2: Select a GPU Pod
1. Go to **Pods** -> **Deploy**.
2. Select the **same Data Center** as your Network Volume.
3. Choose an NVIDIA GPU suited for your model size:
   * **Qwen 14B / 27B Quantized (Q4_K_M)**: 1x RTX 3090, RTX 4090, or A5000 (24GB VRAM).
   * **Qwen 27B / 32B (Q8 / FP16)**: 1x A6000 (48GB VRAM) or 1x A100 (80GB VRAM).

### Step 3: Configure the Pod Template
1. Click **Customize Pod**.
2. **Container Image**: `ghcr.io/<your-username>/runpod-ollama:latest` (or `<your-dockerhub-username>/runpod-ollama:latest`)
3. **Volume Mount Path**: Set to `/root/.ollama` and attach `ollama-storage`.
4. **Port Configuration (CRITICAL)**:
   * **DO NOT** use the RunPod HTTP Proxy toggle!
   * Add port `8443` as an **Exposed TCP Port**.
   * RunPod will display a direct TCP mapping, for example: `69.164.120.45:19842 -> 8443/TCP`.
5. **Environment Variables**:
   ```env
   MODEL=llama3.1:8b
   API_KEY=sk-super-secret-production-key-991823
   HTTPS_PORT=8443
   DOMAIN=llm.example.com
   ACME_EMAIL=admin@example.com
   OLLAMA_KEEP_ALIVE=30m
   ```
   *(If using MODE B without a domain, omit `DOMAIN`).*
6. Click **Deploy On-Demand**.

---

## 7. Verifying That the RunPod HTTP Proxy is NOT Being Used

You can verify that traffic bypasses RunPod's HTTP proxy using two checks:

1. **Endpoint URL Format**:
   * **RunPod HTTP Proxy (INSECURE)**: Uses URLs formatted like `https://<pod-id>-8443.proxy.runpod.net`.
   * **Direct TCP Forwarding (SECURE)**: Uses your custom domain or RunPod public IP with custom port: `https://llm.example.com:19842` or `https://69.164.120.45:19842`.
2. **TLS Certificate Inspection**:
   Run:
   ```bash
   openssl s_client -connect 69.164.120.45:19842 -servername llm.example.com </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject
   ```
   * If issuer shows `Caddy Internal Authority` (Mode B) or `Let's Encrypt` (Mode A), TLS is terminating **inside** your Pod.
   * If issuer shows Cloudflare or RunPod Proxy CA, traffic is terminating at an external proxy.

---

## 8. Testing the API

### 1. List Models (`GET /v1/models`)
```bash
curl -k https://YOUR_HOST:MAPPED_PORT/v1/models \
  -H "Authorization: Bearer $API_KEY"
```

### 2. Verify Authentication Rejection
```bash
curl -k -i https://YOUR_HOST:MAPPED_PORT/v1/models \
  -H "Authorization: Bearer wrong-key"
```
Expected output:
```http
HTTP/2 401
content-type: text/plain; charset=utf-8

Unauthorized: Invalid or missing API key
```

### 3. Safe Streaming Chat Completion (`POST /v1/chat/completions`)
```bash
curl -k https://YOUR_HOST:MAPPED_PORT/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.1:8b",
    "messages": [
      {
        "role": "user",
        "content": "Hello! Explain why in-pod TLS is important."
      }
    ],
    "stream": true
  }'
```

### 4. OpenAI Python SDK Example
```python
import os
import httpx
from openai import OpenAI

# In MODE B (No Domain / Self-Signed), disable SSL verification on the client
http_client = httpx.Client(verify=False)

client = OpenAI(
    base_url="https://69.164.120.45:19842/v1",  # Or https://llm.example.com:19842/v1
    api_key=os.environ.get("API_KEY", "sk-super-secret-production-key-991823"),
    http_client=http_client,
)

# Streaming completion
stream = client.chat.completions.create(
    model="llama3.1:8b",
    messages=[
        {"role": "user", "content": "Write a 3-sentence summary of zero-trust architecture."}
    ],
    stream=True,
)

for chunk in stream:
    if chunk.choices and chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)
print()
```

---

## 9. Model Management & Persistent Storage

### Switching Models
To change models, edit the `MODEL` environment variable in your RunPod Pod template:
* `MODEL=llama3.1:8b`
* `MODEL=qwen2.5:14b`
* `MODEL=qwen2.5:32b`
* `MODEL=mistral:7b`

### Pod Recreation Lifecycle
```text
Component           Storage Location       Lifespan
───────────────────────────────────────────────────────────────────
Docker Image        Container Registry     Permanent
Model Weights       Network Volume         Permanent (/root/.ollama)
TLS State           Network Volume         Permanent (/data/caddy)
Pod Runtime         RunPod GPU Host        Ephemeral / Disposable
```

When you terminate the Pod to stop billing:
1. Model files remain saved on the RunPod Network Volume.
2. When creating a new Pod, re-attach the volume to `/root/.ollama`.
3. Startup checks `/api/tags`, identifies the model as `[model] already installed`, and boots Caddy immediately without re-downloading.

---

## 10. Health Check Probe

The included `/app/healthcheck.sh` tests:
1. Ollama loopback HTTP API responsiveness (`curl http://127.0.0.1:11434/api/tags`).
2. Caddy daemon process health (`pgrep -x caddy`).
3. Model catalog availability in Ollama.

Sensitive prompts, completions, and tokens are never emitted by the health probe.
