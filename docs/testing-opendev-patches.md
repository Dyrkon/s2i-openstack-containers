# Testing OpenDev changes with S2I

How to build an S2I service image that includes an **unmerged** OpenDev (Gerrit) change and push it to a registry.

This guide stops at a published image URL. Pointing a control-plane deploy at that URL (OpenStackVersion / ci-framework) is a separate step — see [OpenStackVersion custom images](https://github.com/openstack-k8s-operators/dev-docs/blob/main/version_updates.md#custom-images-for-other-openstack-services) in the openstack-k8s-operators developer docs.

Pins and publication model are documented in [developer-guide.md](https://github.com/openstack-k8s-operators/s2i-openstack-containers/blob/main/docs/developer-guide.md) and [design.md](https://github.com/openstack-k8s-operators/s2i-openstack-containers/blob/main/docs/design.md). Wiring speculative Zuul jobs on an operator repo is covered in [operator-onboarding.md](https://github.com/openstack-k8s-operators/s2i-openstack-containers/blob/main/docs/operator-onboarding.md).

## Concepts

| Term | Meaning |
| ---- | ------- |
| **Pin** | Commit hash in `containers/<project>/sources.txt`. Service images are built from these pins. |
| **Stream** | First column in `sources.txt` (usually `master`). Selects which pins a build uses and the Quay tag prefix (`master-latest`, `master-<sha>`). |
| **Tracked branch** | Fourth column in `sources.txt` (for example `stable/2026.2`). What the daily `update-sources` job follows. |
| **Service image** | Published image such as `quay.io/openstack-s2i-containers/openstack-keystone:master-latest`. |
| **openstack-base** | Shared base layer. It does **not** contain the service under test. |

Source pins live in this repository (`sources.txt` at project and, when needed, image level). Changing an operator image URL or catalog entry does not rebuild the service — the patched code must already be present in the referenced image.

## How merged code reaches Quay

```text
OpenDev merge on the tracked branch
        │
        ▼
Daily update-sources → PR → merge to main
        │
        ▼
Post-merge build/push → quay.io/openstack-s2i-containers/<image>:master-latest
```

Unmerged work is never in Quay until you stage it into a custom build (below) or a speculative CI job builds it.

## Choose an approach

| Goal | Approach |
| ---- | -------- |
| Prove a change in Zuul without a personal registry | Speculative CI (`*-s2i-content-provider` / OpenDev `s2i-speculative-build` + `Depends-On`) — see [operator-onboarding.md](https://github.com/openstack-k8s-operators/s2i-openstack-containers/blob/main/docs/operator-onboarding.md) |
| Custom image for CRC / testproject / local override | **Build and push here**, then override the image URL via OpenStackVersion (or ci-framework variables that write it) |
| Change already merged on the tracked branch | Wait for `update-sources` PR merge → Quay publish → redeploy |

## Build a custom image from an OpenDev change

When `build.sh` finds an existing checkout under `containers/<project>/src/<name>/`, it builds that tree and does **not** replace it with the SHA from `sources.txt`. That is the supported way to test an in-flight OpenDev change.

### 1. Resolve the build target and OpenStackVersion field

```bash
./build.sh list
# Source-based projects only (repos listed in sources.txt):
# PARALLEL=1 ./build.sh auto-detect openstack/<project>
```

`auto-detect` matches git URLs from `sources.txt`. It does **not** resolve PyPI-only projects such as `python-openstackclient`; use `./build.sh list` and [containers/image-mappings.yaml](https://github.com/openstack-k8s-operators/s2i-openstack-containers/blob/main/containers/image-mappings.yaml) instead.

Map the image to an OpenStackVersion field via that mapping file. Examples:

`keystone/keystone` → `keystoneAPIImage`

`openstackclient/openstackclient` → `openstackClientImage`

You need that field name when you later set `spec.customContainerImages` (or `cifmw_update_containers_custom_images`) on the deploy side.

Check the Gerrit change's target branch against the tracked branch in `sources.txt` (column 4). Fetching a patchset checks out its complete source tree; it does not rebase the patch onto the pinned commit. Testing a change aimed at a different branch may pull in unrelated commits or dependency incompatibilities.

### 2. Stage the OpenDev change (source-based projects)

Most services (Keystone, Glance, Cinder, …) clone upstream git into `containers/<project>/src/<name>/`. Existing checkouts are used as-is and are not removed by `build.sh` on exit.

Gerrit ref pattern: `refs/changes/XX/NNNNN/P` where `XX` is the last two digits of the change number (zero-padded, for example change `5` → `05/5`).

```bash
cd /path/to/s2i-openstack-containers
./build.sh install-deps   # once

PROJECT=keystone          # containers/<project>/
SRC_NAME=keystone         # destination under src/ (usually same as project)
GERRIT_REF=refs/changes/XX/NNNNN/P

mkdir -p "containers/${PROJECT}/src"
rm -rf "containers/${PROJECT}/src/${SRC_NAME}"  # removes any existing local checkout
git clone "https://opendev.org/openstack/${SRC_NAME}.git" \
  "containers/${PROJECT}/src/${SRC_NAME}"
git -C "containers/${PROJECT}/src/${SRC_NAME}" fetch \
  "https://review.opendev.org/openstack/${SRC_NAME}" "${GERRIT_REF}"
git -C "containers/${PROJECT}/src/${SRC_NAME}" checkout --detach FETCH_HEAD
```

If you use [git-review](https://docs.openstack.org/infra/git-review/), an equivalent staging step is `git review -d <change>` inside `containers/${PROJECT}/src/${SRC_NAME}` after cloning the project.

### 3. Build and push

Reuse the published base image. Set `REGISTRY` / `NAMESPACE` / `TAG` at build time so the local tag matches what you push.

```bash
IMAGE_TARGET=keystone/keystone   # from ./build.sh list
QUAY_NS=<your-quay-namespace>
TAG=keystone-<change>

STREAM=master \
BASE_IMAGE=quay.io/openstack-s2i-containers/openstack-base:master-latest \
PBR_VERSION_FROM_GIT=true \
REGISTRY=quay.io \
NAMESPACE="${QUAY_NS}" \
TAG="${TAG}" \
./build.sh build "${IMAGE_TARGET}"

# equivalent via tox:
# STREAM=master PBR_VERSION_FROM_GIT=true \
#   BASE_IMAGE=quay.io/openstack-s2i-containers/openstack-base:master-latest \
#   REGISTRY=quay.io NAMESPACE="${QUAY_NS}" TAG="${TAG}" \
#   tox -e build -- "${IMAGE_TARGET}"

STREAM=master REGISTRY=quay.io NAMESPACE="${QUAY_NS}" TAG="${TAG}" \
  ./build.sh push "${IMAGE_TARGET}"
```

Substitute your Quay namespace and image tag for `<QUAY_NS>` / `<your-quay-namespace>` and `<TAG>` (do not paste the angle brackets literally).

Notes:

- `BASE_IMAGE` is the shared base only. Service code still comes from `containers/<project>/src/`.
- `PBR_VERSION_FROM_GIT=true` is required for development checkouts so PBR does not use the version recorded in `sources.txt`.
- If the change updates `requirements.txt` or other dependency inputs, regenerate locks from the staged tree before building: `STREAM=master ./build.sh sync-locks <project>` (see [developer-guide.md](https://github.com/openstack-k8s-operators/s2i-openstack-containers/blob/main/docs/developer-guide.md#relocking-staged-sources-speculative-ci)). Code-only patches do not need this.
- Default local tag (if you omit `REGISTRY`/`NAMESPACE`/`TAG`) is `localhost/openstack/openstack-<dirname>:master-latest` (for example `localhost/openstack/openstack-keystone:master-latest`). Retag before push if needed.
- The Quay repository must be public, or the target cluster must have pull credentials.

After push, override the matching OpenStackVersion field (from `image-mappings.yaml`) with your Quay URL. Details live in [dev-docs version_updates.md](https://github.com/openstack-k8s-operators/dev-docs/blob/main/version_updates.md#custom-images-for-other-openstack-services).

## Component differences (build)

### Source-based services

Default path above. One upstream repo in `sources.txt` (plus `upper-constraints`), installed from `src/` during the image build. Keystone is the typical single-image example (`keystone/keystone` → `keystoneAPIImage`).

### Multi-image projects

Projects such as Cinder or Neutron produce several images from the same `src/` tree. Stage the change once under `containers/<project>/src/`, then build each target you need (`cinder/cinder-api`, `cinder/cinder-scheduler`, …). Override every corresponding OpenStackVersion field from `image-mappings.yaml` when you deploy.

### openstackclient (PyPI-based)

`containers/openstackclient` lists only `upper-constraints` in `sources.txt`. Clients are installed from PyPI via `pythondeps.txt`; there is no git `src/` tree for `build.sh` to consume. This is intentional (sources-less / PyPI Containerfile support); check `sources.txt` and the Containerfile if that layout changes.

To test an unmerged `python-openstackclient` (or another client listed in `pythondeps.txt`) change, layer it onto the published S2I image:

```bash
QUAY_NS=<your-quay-namespace>
TAG=openstackclient-<change>
WORK=/tmp/osc-custom
mkdir -p "${WORK}/src"
git clone https://opendev.org/openstack/python-openstackclient.git \
  "${WORK}/src/python-openstackclient"
git -C "${WORK}/src/python-openstackclient" fetch \
  https://review.opendev.org/openstack/python-openstackclient \
  refs/changes/XX/NNNNN/P
git -C "${WORK}/src/python-openstackclient" checkout --detach FETCH_HEAD

cat > "${WORK}/Containerfile" <<'EOF'
ARG BASE_IMAGE=quay.io/openstack-s2i-containers/openstack-openstackclient:master-latest
FROM ${BASE_IMAGE}
USER root
COPY src/python-openstackclient /tmp/python-openstackclient
# Prefer --no-deps (or -c against the image lockfile) so transitive
# dependencies stay aligned with the published S2I image.
RUN pip3 install --no-cache-dir --prefix=/usr --force-reinstall --no-deps \
      /tmp/python-openstackclient \
    && rm -rf /tmp/python-openstackclient
USER cloud-admin
WORKDIR /home/cloud-admin
EOF

podman build -t "quay.io/${QUAY_NS}/openstack-openstackclient:${TAG}" \
  -f "${WORK}/Containerfile" "${WORK}"
podman push "quay.io/${QUAY_NS}/openstack-openstackclient:${TAG}"
```

This overlay is for client changes compatible with the published image's existing dependencies. Changes that need new or updated transitive dependencies need a rebuilt image with refreshed locks instead.

When deploying, override `openstackClientImage` the same way as any other `customContainerImages` / `cifmw_update_containers_custom_images` field.

### Horizon and other multi-source projects

Some projects pin several repos in one `sources.txt` (for example Horizon plus dashboards). Stage the patched repo under the matching `src/<name>/` directory from that file. Sibling pins stay at the committed hash unless you also replace those trees.

## FAQ

**Does an OpenDev merge land in Quay automatically?**
No. Pin bump PR → merge → Quay publish. A running cluster still needs a redeploy/pull or an OpenStackVersion override.

**Does the daily update-sources job merge itself?**
No. It opens or updates a PR; `main` moves when that PR merges.

**Can I use** `src/overrides/` **instead of replacing the main checkout?**
Yes for source-based Containerfiles that install from `/src/overrides/`. That path is for patched **transitive** dependencies. For the main service repo under review, replace `containers/<project>/src/<name>/` as shown above.
