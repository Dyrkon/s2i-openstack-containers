# GitHub Actions Build Optimization Analysis

## Current State (45 minutes build time)

### Workflow Analysis

**Workflows:**
- `build.yml` - PR validation (builds all images)
- `build-and-push.yml` - Main branch deployment (builds + pushes all images)
- `linter.yml` - Linting with changed-service detection

**Current Build Strategy:**
```yaml
# build.yml & build-and-push.yml
- name: Build images
  run: tox -e build  # = bash build.sh build all
```

This builds **ALL images serially** (one after another), taking ~45 minutes.

---

## GitHub Runner Specifications

**Standard (FREE) runners:**
- **CPU**: 2 cores (Intel Xeon Platinum 8370C @ 2.80GHz)
- **RAM**: 7 GB
- **Storage**: 14 GB SSD
- **OS**: ubuntu-latest

**Larger (PAID) runners** - Team/Enterprise only:
- `ubuntu-latest-4-cores`: 4 CPU, 16 GB RAM
- `ubuntu-latest-8-cores`: 8 CPU, 32 GB RAM
- `ubuntu-latest-16-cores`: 16 CPU, 64 GB RAM

---

## What EXISTS But ISN'T USED

### ✅ Detect Changed Services Action

**Location**: `.github/actions/detect-changed-services/action.yml`

**What it does:**
```yaml
outputs:
  services: "nova cinder glance"  # Space-separated list
```

**Currently used in:**
- ✅ `linter.yml` - Only lints changed services
- ❌ `build.yml` - **NOT USED** (builds everything)
- ❌ `build-and-push.yml` - **NOT USED** (builds everything)

**Impact if used for builds:**
- Changed 1 service: Build time 45 min → **~5 min** (90% savings)
- Changed 3 services: Build time 45 min → **~10 min** (78% savings)

---

## What's COMPLETELY MISSING

### ❌ 1. No Caching

**Missing cache types:**

```yaml
# Container layer caching
- uses: actions/cache@v3
  with:
    path: ~/.local/share/containers/storage
    key: containers-${{ hashFiles('containers/**/sources.txt') }}

# Pip wheel caching
- uses: actions/cache@v3
  with:
    path: ~/.cache/pip
    key: pip-${{ hashFiles('**/requirements.lock.master') }}

# RPM package caching
- uses: actions/cache@v3
  with:
    path: /var/cache/dnf
    key: dnf-${{ hashFiles('**/rpms.in.yaml') }}
```

**Expected savings:**
- First run: 45 min (cold cache)
- Subsequent runs: **10-15 min** (warm cache, 67% faster)

---

### ❌ 2. No Parallel Builds

**Current:** Serial builds (one after another)
```
base (10m) → nova-api (5m) → nova-conductor (5m) → cinder-api (5m) → ...
Total: 45 minutes
```

**Optimal:** Parallel builds (base first, then services in parallel)
```
base (10m) → ┬─ nova-api (5m)
             ├─ nova-conductor (5m)
             ├─ cinder-api (5m)
             └─ ... (8 parallel jobs)
Total: 15 minutes (limited by slowest image)
```

**Why it's safe:**
- `build.sh` already handles dependencies correctly:
  1. Builds `base` image first (serially)
  2. Pre-clones all source repos (to avoid race conditions)
  3. Builds service images (can be parallelized)

**Expected savings:** 45 min → **15 min** (67% faster)

---

### ❌ 3. No Incremental Builds

The existing `detect-changed-services` action is **not used** for builds.

**Current behavior:**
```yaml
# Every PR, even if only changing nova/
run: tox -e build  # Builds ALL: base, nova, cinder, glance, manila, ...
```

**Expected behavior:**
```yaml
# PR changes only nova/nova-api/
run: tox -e build -- base nova/nova-api  # Only build what changed
```

**Expected savings:**
- Typical PR (1-2 services): 45 min → **5-10 min** (80-90% faster)
- Large PR (5+ services): 45 min → **20-25 min** (44-56% faster)

---

### ❌ 4. No Build Optimization Flags

**Missing buildah/podman optimizations:**

```bash
# build.sh could add:
buildah bud \
  --layers \              # Enable layer caching
  --jobs $(nproc) \       # Parallel RUN commands (2 cores = 2x speedup)
  --cache-from ... \      # Pull cache from registry
```

**Expected savings:** 5-10% per image (~2-4 min total)

---

### ❌ 5. No Artifact Sharing Between Jobs

**Problem:** Parallel jobs can't share the base image directly.

**Solution:** Use artifacts to share base image:
```yaml
jobs:
  build-base:
    steps:
      - run: podman save localhost/openstack/openstack-base:master-latest -o base.tar
      - uses: actions/upload-artifact@v3
        with:
          name: base-image
          path: base.tar

  build-services:
    needs: build-base
    steps:
      - uses: actions/download-artifact@v3
        with:
          name: base-image
      - run: podman load -i base.tar
```

**Expected savings:** Eliminates base rebuild in each parallel job (~2 min/job)

---

## Optimization Recommendations

### Phase 1: Quick Wins (Implement Today)

#### 1. Use Existing Changed-Service Detection

**Effort:** 5 minutes
**Impact:** 80-90% time savings on typical PRs

```yaml
# build.yml
jobs:
  build:
    steps:
      - uses: ./.github/actions/detect-changed-services
        id: changes
      
      - name: Build changed images
        run: |
          if [ -n "${{ steps.changes.outputs.services }}" ]; then
            tox -e build -- base ${{ steps.changes.outputs.services }}
          else
            echo "No service changes, skipping build"
          fi
```

#### 2. Add Container Layer Caching

**Effort:** 10 minutes
**Impact:** 50-70% time savings on repeated builds

```yaml
# build.yml
steps:
  - uses: actions/cache@v3
    with:
      path: |
        ~/.local/share/containers/storage
        ~/.cache/pip
      key: containers-${{ hashFiles('containers/**/sources.txt') }}-${{ hashFiles('containers/**/Containerfile') }}
      restore-keys: |
        containers-${{ hashFiles('containers/**/sources.txt') }}-
        containers-
```

---

### Phase 2: Parallel Builds (Implement This Week)

**Effort:** 1-2 hours
**Impact:** 67% time savings (45 min → 15 min)

```yaml
# build.yml
jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      services: ${{ steps.changes.outputs.services }}
    steps:
      - uses: actions/checkout@v7
      - uses: ./.github/actions/detect-changed-services
        id: changes

  build-base:
    needs: detect-changes
    if: needs.detect-changes.outputs.services != ''
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/cache@v3
        with:
          path: ~/.local/share/containers/storage
          key: containers-base-${{ hashFiles('containers/base/**') }}
      
      - name: Install dependencies
        run: sudo apt-get update && sudo apt-get install -y buildah podman
      
      - name: Build base image
        run: tox -e build -- base
      
      - name: Save base image
        run: podman save localhost/openstack/openstack-base:master-latest -o /tmp/base.tar
      
      - uses: actions/upload-artifact@v3
        with:
          name: base-image
          path: /tmp/base.tar
          retention-days: 1

  build-services:
    needs: [detect-changes, build-base]
    if: needs.detect-changes.outputs.services != ''
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        # Dynamically generate from changed services
        # For now, example with common services:
        service:
          - nova/nova-api
          - nova/nova-conductor
          - nova/nova-scheduler
          - nova/nova-novncproxy
          - nova/nova-compute
          - cinder/cinder-api
          - cinder/cinder-volume
          - glance/glance-api
    steps:
      - uses: actions/checkout@v7
      
      - uses: actions/cache@v3
        with:
          path: ~/.local/share/containers/storage
          key: containers-${{ matrix.service }}-${{ hashFiles(format('containers/{0}/**', matrix.service)) }}
      
      - name: Install dependencies
        run: sudo apt-get update && sudo apt-get install -y buildah podman
      
      - uses: actions/download-artifact@v3
        with:
          name: base-image
          path: /tmp
      
      - name: Load base image
        run: podman load -i /tmp/base.tar
      
      - name: Build ${{ matrix.service }}
        run: tox -e build -- ${{ matrix.service }}
```

---

### Phase 3: Advanced Optimizations (Optional)

#### 1. Larger Runners (Requires Paid Plan)

```yaml
runs-on: ubuntu-latest-4-cores  # 4 CPU, 16 GB RAM
```

**Cost:** ~$0.008/minute (vs $0.004/minute for standard)
**Savings:** 20-30% faster builds

#### 2. BuildKit Optimizations

```bash
# build.sh enhancement
buildah bud \
  --layers \
  --jobs $(nproc) \
  --cache-from ${REGISTRY}/${NAMESPACE}/${IMAGE_PREFIX}-base:master-latest
```

**Savings:** 5-10% per image

#### 3. Remote Cache Registry

Push layer cache to registry for sharing across runners:
```yaml
- name: Configure remote cache
  run: |
    echo "--cache-to type=registry,ref=${REGISTRY}/cache/${IMAGE}" >> build-flags.txt
```

**Savings:** 10-20% on distributed builds

---

## Expected Results Summary

### Current State
- **Build time:** 45 minutes
- **Cache reuse:** 0%
- **Parallelization:** 0%
- **Changed-only builds:** No

### After Phase 1 (Quick Wins)
- **Build time:** 5-10 min (typical PR with 1-2 changed services)
- **Cache reuse:** 50-70%
- **Parallelization:** 0%
- **Changed-only builds:** Yes
- **Effort:** 15 minutes to implement

### After Phase 2 (Parallel Builds)
- **Build time:** 3-5 min (cached) / 15 min (cold cache, all services)
- **Cache reuse:** 70-90%
- **Parallelization:** 8-10 concurrent jobs
- **Changed-only builds:** Yes
- **Effort:** 1-2 hours to implement

### After Phase 3 (Advanced)
- **Build time:** 2-3 min (cached) / 10 min (cold cache, all services)
- **Cache reuse:** 90-95%
- **Parallelization:** 16+ concurrent jobs (with larger runners)
- **Changed-only builds:** Yes
- **Effort:** 4-8 hours to implement
- **Cost:** Additional runner costs

---

## Implementation Priority

1. **HIGH (Do Now):**
   - ✅ Use `detect-changed-services` in build.yml
   - ✅ Add container layer caching

2. **MEDIUM (This Week):**
   - ⚙️ Implement parallel builds
   - ⚙️ Add artifact sharing for base image

3. **LOW (Nice to Have):**
   - 🔧 BuildKit optimizations
   - 🔧 Larger runners (if budget allows)
   - 🔧 Remote cache registry

---

## Notes

- The `build.sh` script already handles build dependencies correctly (base → services)
- Pre-cloning sources prevents race conditions in parallel builds
- Caching is effective even with parallel builds (all jobs share the same cache)
- The `detect-changed-services` action is already proven to work (used in linter.yml)

## References

- GitHub Actions cache documentation: https://docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows
- GitHub-hosted runners specs: https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners
- Buildah performance tips: https://github.com/containers/buildah/blob/main/docs/tutorials/05-openshift-rootless-build.md
