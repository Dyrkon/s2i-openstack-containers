#!/usr/bin/env bash
# Tests for image-mappings keys and the deploy-validation skip list.
#
# s2i-openstack-deploy-validation still maps built s2i images onto
# OpenStackVersion.spec.customContainerImages, but omits unready keys
# so preserve_unlisted: true keeps payload defaults. This test checks
# that skip-list filtering drops those keys without removing them from
# containers/image-mappings.yaml.
#
# Usage:
#   bash tests/test_deployment_keys.sh
#   tox -e test
#
set -uo pipefail

# ── Test runner ──────────────────────────────────────────────────────────

_PASS=0
_FAIL=0

assert() {
  local desc="$1"
  shift
  if "$@"; then
    return 0
  fi
  echo "    ASSERTION FAILED: ${desc}"
  echo "      command: $*"
  return 1
}

assert_in_lines() {
  local needle="$1"
  local haystack="$2"
  local desc="$3"
  if printf '%s\n' "${haystack}" | grep -qxF "${needle}"; then
    return 0
  fi
  echo "    ASSERTION FAILED: ${desc}"
  return 1
}

assert_not_in_lines() {
  local needle="$1"
  local haystack="$2"
  local desc="$3"
  if printf '%s\n' "${haystack}" | grep -qxF "${needle}"; then
    echo "    ASSERTION FAILED: ${desc}"
    return 1
  fi
  return 0
}

run_test() {
  local name="$1"
  local rc=0
  ( set -e; "${name}" ) || rc=$?

  if [[ ${rc} -eq 0 ]]; then
    echo "  PASS  ${name}"
    ((_PASS++))
  else
    echo "  FAIL  ${name}"
    ((_FAIL++))
  fi
}

# ── Helpers ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE_MAPPINGS="${SCRIPT_DIR}/containers/image-mappings.yaml"
JOBS_YAML="${SCRIPT_DIR}/zuul.d/jobs.yaml"

# Unready OpenStackVersion keys omitted by s2i-openstack-deploy-validation.
SKIP_KEYS="$(printf '%s\n' \
  neutronAPIImage \
  edpmNeutronMetadataAgentImage \
  mariadbImage \
  horizonImage \
  manilaAPIImage \
  manilaSchedulerImage \
  novaAPIImage \
  glanceAPIImage)"

# Neutron/OVN keys that must still be injected during deploy-validation.
READY_NEUTRON_OVN_KEYS="$(printf '%s\n' \
  edpmNeutronDhcpAgentImage \
  edpmNeutronOvnAgentImage \
  edpmNeutronSriovAgentImage \
  ironicNeutronAgentImage \
  ovnControllerImage \
  ovnControllerOvsImage \
  ovnNbDbclusterImage \
  ovnNorthdImage \
  ovnSbDbclusterImage)"

extract_mapped_keys() {
  awk '
    /^  custom_container_images:/ { in_section=1; next }
    in_section && /^[^ ]/ { exit }
    in_section && $1 == "-" { print $2 }
  ' "${IMAGE_MAPPINGS}"
}

extract_job() {
  local job_name="$1"
  awk -v name="${job_name}" '
    BEGIN { found=0; collecting=0 }
    found && /^- / { exit }
    /^- job:/ {
      collecting=1
      next
    }
    collecting && /^    name: / {
      if ($2 == name) {
        found=1
        print "- job:"
        print $0
      } else {
        collecting=0
      }
      next
    }
    found { print }
  ' "${JOBS_YAML}"
}

job_skip_list() {
  local job_name="$1"
  local block
  block="$(extract_job "${job_name}")"
  if printf '%s\n' "${block}" | grep -qE '^      s2i_ci_skip_os_custom_images:[[:space:]]*\[\][[:space:]]*$'; then
    return 0
  fi
  printf '%s\n' "${block}" | awk '
    /^      s2i_ci_skip_os_custom_images:[[:space:]]*$/ { in_var=1; next }
    in_var && /^        - / { print $2; next }
    in_var && /^        #/ { next }
    in_var { exit }
  '
}

omit_skipped() {
  local skip_list="$1"
  local images="$2"
  local key
  while IFS= read -r key; do
    [[ -z "${key}" ]] && continue
    if [[ -n "${skip_list}" ]] && printf '%s\n' "${skip_list}" | grep -qxF "${key}"; then
      continue
    fi
    printf '%s\n' "${key}"
  done <<< "${images}"
}

count_lines() {
  local text="$1"
  if [[ -z "${text}" ]]; then
    printf '%s\n' 0
    return 0
  fi
  local n
  n="$(printf '%s\n' "${text}" | grep -c . || true)"
  printf '%s\n' "${n:-0}"
}

sorted_lines() {
  local text="$1"
  if [[ -z "${text}" ]]; then
    return 0
  fi
  printf '%s\n' "${text}" | grep -v '^$' | sort
}

# ── Tests ────────────────────────────────────────────────────────────────

test_skip_keys_remain_in_global_image_mappings() {
  local mapped key
  mapped="$(extract_mapped_keys)"
  while IFS= read -r key; do
    [[ -z "${key}" ]] && continue
    assert_in_lines "${key}" "${mapped}" \
      "skip-list key ${key} must stay in image-mappings.yaml"
  done <<< "${SKIP_KEYS}"
}

test_ready_neutron_ovn_keys_remain_mapped() {
  local mapped key
  mapped="$(extract_mapped_keys)"
  while IFS= read -r key; do
    [[ -z "${key}" ]] && continue
    assert_in_lines "${key}" "${mapped}" \
      "ready neutron/ovn key ${key} must stay mapped"
  done <<< "${READY_NEUTRON_OVN_KEYS}"
}

test_only_mariadb_image_is_mapped_for_galera() {
  local keys
  keys="$(awk '
    /^    (mariadb|galera)\// { in_t=1; next }
    in_t && /^    [^ #]/ { in_t=0 }
    in_t && $1 == "-" { print $2 }
  ' "${IMAGE_MAPPINGS}")"
  assert "only mariadbImage is mapped for mariadb/galera" \
    test "${keys}" = "mariadbImage"
}

test_skip_list_drops_unready_keys() {
  local mapped filtered key mapped_count filtered_count skip_count
  mapped="$(extract_mapped_keys)"
  filtered="$(omit_skipped "${SKIP_KEYS}" "${mapped}")"

  while IFS= read -r key; do
    [[ -z "${key}" ]] && continue
    assert_not_in_lines "${key}" "${filtered}" \
      "unready key ${key} must be omitted from the filtered map"
  done <<< "${SKIP_KEYS}"

  while IFS= read -r key; do
    [[ -z "${key}" ]] && continue
    assert_in_lines "${key}" "${filtered}" \
      "ready neutron/ovn key ${key} must remain after filtering"
  done <<< "${READY_NEUTRON_OVN_KEYS}"

  mapped_count="$(count_lines "${mapped}")"
  filtered_count="$(count_lines "${filtered}")"
  skip_count="$(count_lines "${SKIP_KEYS}")"
  assert "filtered map drops exactly the skip-list keys" \
    test "${filtered_count}" -eq "$((mapped_count - skip_count))"
}

test_empty_skip_list_is_identity() {
  local fake filtered
  fake="$(printf '%s\n' neutronAPIImage glanceAPIImage mariadbImage)"
  filtered="$(omit_skipped "" "${fake}")"
  assert "empty skip list leaves the map unchanged" \
    test "${filtered}" = "${fake}"
}

test_deploy_validation_job_sets_skip_list() {
  local actual expected
  actual="$(sorted_lines "$(job_skip_list s2i-openstack-deploy-validation)")"
  expected="$(sorted_lines "${SKIP_KEYS}")"
  assert "deploy-validation skip list matches expected keys" \
    test "${actual}" = "${expected}"
}

test_base_job_skip_list_is_empty() {
  local skip
  skip="$(job_skip_list s2i-speculative-deploy-test-base)"
  assert "base job skip list is empty" test -z "${skip}"
}

test_content_provider_does_not_set_skip_list() {
  local block skip
  block="$(extract_job s2i-openstack-container-content-provider)"
  skip="$(job_skip_list s2i-openstack-container-content-provider)"
  assert "content provider skip list is empty" test -z "${skip}"
  if printf '%s\n' "${block}" | grep -q 's2i_ci_skip_os_custom_images'; then
    echo "    ASSERTION FAILED: content provider must not set s2i_ci_skip_os_custom_images"
    return 1
  fi
}

# ── Run all tests ────────────────────────────────────────────────────────

echo "=== image-mappings and deploy-validation skip-list tests ==="
echo ""

TESTS=(
  test_skip_keys_remain_in_global_image_mappings
  test_ready_neutron_ovn_keys_remain_mapped
  test_only_mariadb_image_is_mapped_for_galera
  test_skip_list_drops_unready_keys
  test_empty_skip_list_is_identity
  test_deploy_validation_job_sets_skip_list
  test_base_job_skip_list_is_empty
  test_content_provider_does_not_set_skip_list
)

for t in "${TESTS[@]}"; do
  run_test "${t}"
done

echo ""
echo "=== ${_PASS} passed, ${_FAIL} failed, 0 skipped ==="

[[ ${_FAIL} -eq 0 ]]
