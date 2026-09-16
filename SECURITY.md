# Security Policy

## Reporting Security Vulnerabilities

If you discover a security vulnerability in this repository, please **do not** open a public GitHub issue. Instead:

1. Contact privately: [Security concern details in private communication]
2. Use GitHub Security Advisory: Settings → Security & Analysis → Advisories
3. **Never** disclose security issues publicly until they're patched

## Secrets & Sensitive Data Policy

### ❌ Prohibited in Repository

- AWS API keys, access tokens, or credentials
- Database connection strings with passwords
- Private SSH keys or certificates
- OAuth tokens, API keys, or service account credentials
- kubeconfig files or cluster certificates
- Any value marked as `[REDACTED]`, `***`, or similar in documentation
- Cloud provider secrets (Azure, GCP, etc.)

### ✅ Allowed (Non-Sensitive)

- Public cloud endpoints (e.g., `https://finops.kyndemo.live`)
- Cluster identifiers (e.g., `azr-cru-0001-k01`)
- Service names and namespaces
- Public IP addresses
- Non-sensitive Helm chart values
- Documentation and architecture diagrams

### ✅ Secret Management (Correct Approach)

- Use **External Secrets Operator** or **Sealed Secrets** for Kubernetes
- Store secrets in **Azure Key Vault**, **AWS Secrets Manager**, or similar
- Use **GitHub Secrets** for Actions workflows
- Document how to obtain secrets in SETUP.md (don't store them)

Example:
```bash
# ❌ WRONG
echo "password: my-secret-123" > config.yaml

# ✅ RIGHT
echo "password: ${SECRET_PASSWORD}" > config.yaml
# SECRET_PASSWORD is injected at deploy time
```

## Pre-Commit Validation

All commits are validated with **gitleaks** and **detect-secrets** before being accepted.

### Install Locally

```bash
cd /Users/victorrodriguez/github/kubernetes-ready

# Install pre-commit framework
pip install pre-commit

# Install hooks (runs automatically on git commit)
pre-commit install

# Manual scan (all files)
pre-commit run --all-files

# Bypass hooks (not recommended)
git commit --no-verify
```

### Running Manual Scans

```bash
# Scan entire repo
detect-secrets scan --baseline .secrets.baseline

# Scan specific file
gitleaks detect --source /path/to/file
```

## GitHub Actions Workflow

Every push and pull request runs:
- **gitleaks**: Detects known secret patterns
- **detect-secrets**: ML-based anomaly detection
- **File size check**: Prevents large binary files (> 5MB)

View results in: **Actions → Secret Scan**

## Baseline File (`.secrets.baseline`)

The `.secrets.baseline` file tracks known false positives. If you legitimately need to store a non-secret value that looks like a secret:

1. Run detection: `detect-secrets scan --baseline .secrets.baseline`
2. Review findings: `detect-secrets audit .secrets.baseline`
3. Mark as verified: `detect-secrets audit --action verify .secrets.baseline`
4. Commit baseline: `git add .secrets.baseline`

## Best Practices

1. ✅ Use branch-based protection on `main` and `flux-prod` → requires secret scan pass
2. ✅ Rotate credentials regularly
3. ✅ Use short-lived tokens where possible
4. ✅ Document secret retrieval procedures (don't embed them)
5. ✅ Review GitHub Actions logs for exposed variables
6. ❌ Don't share kubeconfig files, even in private Slack
7. ❌ Don't commit `.env` files
8. ❌ Don't assume old commits are private—Git history is permanent

## File Exclusions

The following directories are scanned (not ignored):

- `kubernetes-ready/` (all Terraform, Helm configs)
- `platform-fleet-poc/` (all manifests)
- `.github/` (Actions workflows)

The following are ignored:

- `.git/` (Git history)
- `node_modules/`, `venv/`, vendor directories
- Binary files (images, PDFs)
- Lock files from dependency managers

## Questions?

- Gitleaks docs: https://github.com/gitleaks/gitleaks
- Detect-secrets docs: https://github.com/Yelp/detect-secrets
- GitHub Security: https://docs.github.com/en/code-security

---

**Last Updated:** 2026-09-16  
**Enforcement:** Mandatory on all branches
