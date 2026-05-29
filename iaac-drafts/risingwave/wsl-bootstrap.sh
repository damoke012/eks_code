#!/usr/bin/env bash
# wsl-bootstrap.sh — first-time setup for a USXpress engineer's WSL distro.
#
# Solves the corporate-CA and dev-tools problem in one shot. Run once on a
# fresh WSL Ubuntu installation; idempotent if re-run.
#
# Symptom this fixes: USXpress proxy does SSL inspection. Without the corp CA
# in WSL's trust store, every HTTPS-using tool (helm, terraform downloads,
# kubectl plugins, curl to public hosts) fails with x509 errors.
#
# Usage:
#   curl -fsSL https://<internal-host>/wsl-bootstrap.sh | bash
#   # or
#   chmod +x wsl-bootstrap.sh && ./wsl-bootstrap.sh
#
# Future home: variant-inc/dev-environment-bootstrap (or similar) — owned by Platform.

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}!!${NC} $*"; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

# Require running on WSL — guard against accidental run on a real Ubuntu host
if ! grep -qi microsoft /proc/version 2>/dev/null && ! grep -qi WSL /proc/version 2>/dev/null; then
  warn "Doesn't look like WSL. Continuing anyway, but the Windows-fallback cert path won't work."
fi

# 1. Install corp CA into WSL trust store
log "Installing USXpress corp CA into WSL trust store"

# Try fetch order:
#  (a) Internal HTTPS endpoint  ← preferred, requires IT to publish
#  (b) S3 bucket with internal-only policy
#  (c) Pre-staged cert at /tmp/usxpress-corp-ca.crt
#  (d) Windows trust store via /mnt/c/Users/$USER/Downloads/

CORP_CA_URL_INTERNAL="${USXPRESS_CORP_CA_URL:-https://intranet.usxpress.com/dev/corp-root-ca.crt}"
CORP_CA_S3="${USXPRESS_CORP_CA_S3:-s3://usxpress-dev-bootstrap/corp-root-ca.crt}"
CORP_CA_WIN="/mnt/c/Users/$USER/Downloads/corp-root-ca.cer"
CORP_CA_PRESTAGED="/tmp/usxpress-corp-ca.crt"

CERT_FOUND=""

if [[ -f "$CORP_CA_PRESTAGED" ]]; then
  CERT_FOUND="$CORP_CA_PRESTAGED"
  log "Using pre-staged cert at $CORP_CA_PRESTAGED"
elif curl -fsSL --max-time 10 -o /tmp/corp-ca.crt "$CORP_CA_URL_INTERNAL" 2>/dev/null; then
  CERT_FOUND="/tmp/corp-ca.crt"
  log "Fetched cert from internal endpoint"
elif command -v aws >/dev/null && aws s3 cp "$CORP_CA_S3" /tmp/corp-ca.crt --quiet 2>/dev/null; then
  CERT_FOUND="/tmp/corp-ca.crt"
  log "Fetched cert from S3"
elif [[ -f "$CORP_CA_WIN" ]]; then
  log "Falling back to Windows trust store export"
  if openssl x509 -inform DER -in "$CORP_CA_WIN" -out /tmp/corp-ca.crt 2>/dev/null; then
    CERT_FOUND="/tmp/corp-ca.crt"
  elif cp "$CORP_CA_WIN" /tmp/corp-ca.crt; then
    # might already be PEM-encoded
    CERT_FOUND="/tmp/corp-ca.crt"
  fi
else
  die "Could not auto-fetch corp CA. Options:
    1. Open ticket with Service Desk asking for 'USXpress corporate root CA certificate'
    2. Export from Windows certmgr.msc → Trusted Root → corp CA → Export → save to:
       $CORP_CA_WIN
    3. Pre-stage at $CORP_CA_PRESTAGED
    Then re-run this script."
fi

# Validate the cert
if ! openssl x509 -in "$CERT_FOUND" -noout -subject 2>/dev/null; then
  die "Cert at $CERT_FOUND is not a valid X.509 cert. Inspect manually."
fi

# Install
sudo cp "$CERT_FOUND" /usr/local/share/ca-certificates/usxpress-corp-ca.crt
sudo update-ca-certificates >/dev/null 2>&1
log "Corp CA installed in /etc/ssl/certs/"

# Verify
log "Verifying HTTPS to public hosts works"
if curl -fsS --max-time 10 https://releases.hashicorp.com/terraform/ >/dev/null 2>&1; then
  log "✓ HTTPS to public hosts works"
else
  warn "HTTPS still failing — corp CA may be wrong, or there's a different issue"
  warn "Try: curl -v https://releases.hashicorp.com/terraform/ 2>&1 | head -40"
  exit 1
fi

# 2. Install standard dev tools
log "Installing standard apt packages"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  curl wget jq unzip git \
  postgresql-client \
  ca-certificates gnupg lsb-release \
  python3-pip python3-venv \
  build-essential

# 3. tfswitch (manages multiple Terraform versions, avoids the apt-repo signing-key issue)
log "Installing tfswitch"
if ! command -v tfswitch >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/warrensbox/terraform-switcher/release/install.sh | sudo bash
fi

# Pin terraform version (matches what iaac-talos uses; adjust if a different version is required)
TF_VERSION="${TF_VERSION:-1.6.6}"
if ! command -v terraform >/dev/null || [[ "$(terraform version -json | jq -r .terraform_version)" != "$TF_VERSION" ]]; then
  log "Installing Terraform $TF_VERSION via tfswitch"
  tfswitch "$TF_VERSION"
fi

# 4. kubectl
log "Installing kubectl"
if ! command -v kubectl >/dev/null; then
  KUBECTL_VERSION="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm /tmp/kubectl
fi

# 5. helm
log "Installing helm"
if ! command -v helm >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# 6. flux CLI
log "Installing flux CLI"
if ! command -v flux >/dev/null; then
  curl -fsSL https://fluxcd.io/install.sh | sudo bash
fi

# 7. AWS CLI v2
log "Installing AWS CLI v2"
if ! command -v aws >/dev/null; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp/
  sudo /tmp/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/aws
fi

# 8. yq
log "Installing yq"
if ! command -v yq >/dev/null; then
  YQ_VERSION="v4.40.5"
  sudo curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq
  sudo chmod +x /usr/local/bin/yq
fi

# Final summary
echo
log "==================================================="
log "WSL bootstrap complete. Installed:"
echo "  curl, jq, postgresql-client, git, openssl"
echo "  terraform $(terraform version -json 2>/dev/null | jq -r .terraform_version || echo 'TBD')"
echo "  kubectl  $(kubectl version --client -o yaml 2>/dev/null | grep gitVersion | head -1 | awk '{print $2}')"
echo "  helm     $(helm version --short 2>/dev/null)"
echo "  flux     $(flux version --client 2>/dev/null | head -1)"
echo "  aws      $(aws --version 2>/dev/null)"
echo "  yq       $(yq --version 2>/dev/null)"
log "==================================================="
echo
log "Next steps:"
echo "  1. Configure AWS SSO: aws configure sso"
echo "     start URL: https://usxpress.awsapps.com/start"
echo "  2. Connect to USXpress VPN before kubectl-ing the on-prem cluster"
echo "  3. Get a kubeconfig from your team lead — see onprem_cluster_access_runbook.md"
