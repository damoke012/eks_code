# WSL `x509: certificate signed by unknown authority` — Corp CA Missing

**Symptom:**
- `helm install`, `curl`, `git`, `gh`, or any HTTPS-aware tool on WSL throws:
  ```
  x509: certificate signed by unknown authority
  ```
- Same operation works from Windows browser / VS Code on Windows side
- Specifically affects corp-internal URLs (Azure DevOps, internal Octopus, etc.) — public CAs work

**Root cause:**
Corp network uses SSL inspection (deep packet inspection via a corp-internal CA). The browser + Windows side trust the corp CA. WSL2 has its own Linux trust store and doesn't automatically inherit the Windows trust.

When WSL tries to talk to a corp-internal URL, the response certificate is signed by the corp CA — which isn't in WSL's trust store — so the validation fails.

**IaC coverage:** ❌ (per-developer setup — not codified for the cluster, but documented for the dev workflow)

**IaC location:** N/A — this is a WSL setup gotcha; document in onboarding

### Resolution via IaC

Not applicable. This is a dev-machine setup issue, not cluster IaC.

### Manual resolution

**Step 1 — Get the corp CA certificate:**

Get the corp CA PEM file from IT or extract from a working Windows browser:

```powershell
# In Windows PowerShell — export from browser-side cert store
# Or ask IT for: USX-RootCA.crt or similar
```

**Step 2 — Install into WSL's trust store (Ubuntu / Debian):**

```bash
# Copy the corp CA into WSL
mkdir -p /usr/local/share/ca-certificates
sudo cp /path/to/corp-ca.crt /usr/local/share/ca-certificates/corp-root-ca.crt

# Run the trust store update
sudo update-ca-certificates

# Verify
ls /etc/ssl/certs/ | grep -i corp
```

**Step 3 — For tools that don't use the system trust (Go, Python with bundled CA):**

```bash
# Go (used by gh, helm, kubectl)
export GOFLAGS="-insecure"  # NOT recommended; better to update GODEBUG
# OR
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# Python (requests/urllib)
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
```

Add these exports to `~/.bashrc` to persist.

### Verification

```bash
# Try the previously-failing command
helm repo update
curl https://<corp-internal-url>
gh auth login
# Expect: no x509 error
```

### Prevention

- Document in dev onboarding for any new on-prem team member
- Add to `~/.bashrc` template for shared dev environments
- ENV var defaults can be set in `/etc/environment` or systemd-environment

### Related

- [[../06-incidents-timeline/]] — none yet; this is a one-time setup gotcha
- Memory: `[WSL corp-CA Helm/curl gotcha]`

### Memory pointers

- `[wsl_corp_ca_helm_cert_gotcha]` — codified gotcha
