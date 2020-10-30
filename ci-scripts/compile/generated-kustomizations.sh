#!/bin/bash

SCRIPT_HOME=$(cd $(dirname ${0}); pwd)
. ${SCRIPT_HOME}/../common.sh "${1}"

# Generate the code first
export TENANT_NAME="${TENANT_NAME:-${EKS_CLUSTER_NAME}}"
export K8S_GIT_URL=${K8S_GIT_URL:-${CI_REPOSITORY_URL}}
export K8S_GIT_BRANCH=${K8S_GIT_BRANCH:-${CI_COMMIT_REF_NAME}}
export TARGET_DIR=/tmp/sandbox

STATUS=0

VARS='${PING_IDENTITY_DEVOPS_USER_BASE64}
${PING_IDENTITY_DEVOPS_KEY_BASE64}
${TENANT_DOMAIN}
${PRIMARY_TENANT_DOMAIN}
${GLOBAL_TENANT_DOMAIN}
${REGION}
${PRIMARY_REGION}
${REGION_NICK_NAME}
${IS_MULTI_CLUSTER}
${CLUSTER_BUCKET_NAME}
${SIZE}
${LETS_ENCRYPT_SERVER}
${PF_PD_BIND_PORT}
${PF_PD_BIND_PROTOCOL}
${PF_PD_BIND_USESSL}
${PF_MIN_HEAP}
${PF_MAX_HEAP}
${PF_MIN_YGEN}
${PF_MAX_YGEN}
${CLUSTER_NAME}
${CLUSTER_NAME_LC}
${CLUSTER_STATE_REPO_URL}
${CLUSTER_STATE_REPO_BRANCH}
${ARTIFACT_REPO_URL}
${PING_ARTIFACT_REPO_URL}
${LOG_ARCHIVE_URL}
${BACKUP_URL}
${K8S_GIT_URL}
${K8S_GIT_BRANCH}
${REGISTRY_NAME}
${ENVIRONMENT_TYPE}
${PING_CLOUD_NAMESPACE}
${KUSTOMIZE_BASE}'

for SIZE in small medium large; do
  log "Building kustomizations for ${SIZE} environment"

  export SIZE
  VARS="${VARS}" "${PROJECT_DIR}/code-gen/generate-cluster-state.sh"

  # Verify that all kustomizations are able to be built
  build_kustomizations_in_dir "${TARGET_DIR}"
  BUILD_STATUS=${?}
  log "Build result for ${SIZE} kustomizations: ${BUILD_RESULT}"

  test ${STATUS} -eq 0 && STATUS=${BUILD_RESULT}
done

exit ${STATUS}