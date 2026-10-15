# Task 1: Dockerization & Secure CI/CD Pipeline — Detailed Guide

## 1. Overview & Architecture

Task 1 establishes the containerization strategy and multi-branch secure delivery pipeline for the lightweight Python memory application. The pipeline ensures that every code change is thoroughly inspected for style, vulnerabilities, hardcoded secrets, and regression before it can be merged into the production branch.

---

## 2. Dockerfile Optimization & Security Hardening

The application is containerized using `Dockerfile` located at the root of the project repository.

### Key Implementation Details:
- **Base Image:** `python:3.11-alpine`
  - *Why:* Minimal attack surface, zero extraneous packages or compilers, resulting in an image size of under 55MB (compared to ~1GB for standard Python images).
- **Non-Root User Execution:**
  - Dedicated group and user `appuser` with UID/GID `10001` created via `addgroup` and `adduser` with `/sbin/nologin`.
  - The container switches to `USER appuser` before starting the application, preventing root privilege escalation.
- **Security & Python Optimization Flags:**
  - `PYTHONDONTWRITEBYTECODE=1`: Avoids writing `.pyc` files on read-only containers.
  - `PYTHONUNBUFFERED=1`: Ensures stdout/stderr logs are flushed immediately to container logs for real-time observability.
- **Port Exposure & Healthcheck:**
  - Port `8080` exposed.
  - Native Docker `HEALTHCHECK` configured against `http://127.0.0.1:8080/healthcheck` with a 10s interval, 3s timeout, and 3 retries.
- **`.dockerignore` Optimization:**
  - Prevents committing local git metadata, test caches, coverage data, manifests, and documentation into the build context, speeding up builds and preventing accidental leakage.

---

## 3. Multi-Branch Secure CI/CD Architecture

Two dedicated GitHub Actions workflows manage the lifecycle across working branches and `main`.

### Pipeline 1: Working Branch PR Pipeline (`.github/workflows/pr-ci.yaml`)
Triggered strictly on `pull_request` against the `main` branch (`opened`, `synchronize`, `reopened`).

```
PR Opened ───► [1. Flake8 Linting] ───► [3. Pytest Unit Tests] ───► [5. Docker Build]
          ───► [2. Bandit SAST]    ───► [4. TruffleHog Secrets]   ───► [6. Trivy Vulnerability Scan]
                                                                                │
                                                                   [PR Merge Gate Approved]
```

#### Security Gates & Scans:
1. **Code Linting (Flake8):**
   - Enforces PEP8 coding standards, detects dead code, unused imports, syntax errors, and whitespace anomalies.
   - Configured via `.flake8` with max line length of 100.
2. **SAST (Static Application Security Testing - Bandit):**
   - Scans Python source code for common security vulnerabilities (injection, weak crypto, unsafe deserialization).
   - Flag `-s B104` explicitly suppresses the false positive for binding to `0.0.0.0` as instructed in the project requirements.
3. **Secret Scanning (TruffleHog):**
   - Inspects commit history and diffs to prevent secrets, tokens, or credentials from leaking into the repository.
4. **Unit Test Suite (Pytest):**
   - Runs `test/test_case.py` validating the health check HTTP 200, JSON response format, 404 handler, memory increment math, and log suppression.
5. **Container Image Vulnerability Scanning (Trivy):**
   - Scans the built container image for operating system and library CVEs, filtering for `CRITICAL` and `HIGH` severity issues.

---

### Pipeline 2: Release Pipeline (`.github/workflows/release.yaml`)
Triggered strictly when code is merged into `main` (push to `main`).

```
Merge to main ──► [Build Matrix: v1.0.0, v1.1.0, v1.2.0] ──► [Push to GHCR] ──► [Auto-Update k8s/deployments.yaml] ──► [Push Commit Back]
```

#### Key Capabilities:
- **Matrix Build:** Builds three distinct image versions simultaneously:
  - `v1.0.0`
  - `v1.1.0`
  - `v1.2.0`
- **Registry Push:** Publishes images to GitHub Container Registry (`ghcr.io/<owner>/memory-app:<tag>`).
- **Automated GitOps Tag Synchronization:**
  - Automatically updates the image references in `k8s/deployments.yaml`.
  - Commits and pushes the manifest updates back to the Git repository, allowing ArgoCD to detect the changes and trigger automatic synchronization without manual intervention.

---

## 4. Branch Protection Guidelines

To satisfy enterprise compliance and security standards:
1. Navigate to **GitHub Repository > Settings > Branches > Add branch ruleset**.
2. Target branch: `main`.
3. Enable:
   - **Require a pull request before merging** (Require approvals: at least 1).
   - **Require status checks to pass before merging**:
     - `Code Quality & SAST Scanning`
     - `Pytest Unit Test Suite`
     - `Secret & Credential Scanning`
     - `Container Build & Vulnerability Scan`
   - **Require branches to be up to date before merging**.
   - **Do not allow bypassing the above settings**.
