#!/usr/bin/env sh

# Check and source environment variable(s) generated by discovery service
test -f "${STAGING_DIR}/ds_env_vars" && . "${STAGING_DIR}/ds_env_vars"

########################################################################################################################
# Function sets required environment variables for skbn
#
########################################################################################################################
function initializeSkbnConfiguration() {
  unset SKBN_CLOUD_PREFIX

  # Allow overriding the backup URL with an arg
  test ! -z "${1}" && BACKUP_URL="${1}"

  # Check if endpoint is AWS cloud storage service (S3 bucket)
  case "$BACKUP_URL" in "s3://"*)
    
    # Set AWS specific variable for skbn
    export AWS_REGION=${REGION}
    
    DIRECTORY_NAME=$(echo "${PING_PRODUCT}" | tr '[:upper:]' '[:lower:]')

    if ! $(echo "$BACKUP_URL" | grep -q "/$DIRECTORY_NAME"); then
      BACKUP_URL="${BACKUP_URL}/${DIRECTORY_NAME}"
    fi

  esac

  export SKBN_CLOUD_PREFIX="${BACKUP_URL}"
}

########################################################################################################################
# Function to copy file(s) between cloud storage and k8s
#
########################################################################################################################
function skbnCopy() {
  PARALLEL="0"
  SOURCE="${1}"
  DESTINATION="${2}"

  # Check if the number of files to be copied in parallel is defined (0 for full parallelism)
  test ! -z "${3}" && PARALLEL="${3}"
  
  if ! skbn cp --src "$SOURCE" --dst "${DESTINATION}" --parallel "${PARALLEL}"; then
    return 1
  fi
}

########################################################################################################################
# Export values for PingDirectory configuration settings based on single vs. multi cluster.
########################################################################################################################
function export_config_settings() {
  export SHORT_HOST_NAME=$(hostname)
  export ORDINAL=${SHORT_HOST_NAME##*-}
  export LOCAL_DOMAIN_NAME="$(hostname -f | cut -d'.' -f2-)"

  # For multi-region:
  # If using NLB to route traffic between the regions, the hostnames will be the same per region (i.e. that of the NLB),
  # but the ports will be different. If using VPC peering (i.e. creating a super network of the subnets) for routing
  # traffic between the regions, then each PD server will be directly addressable, and so will have a unique hostname
  # and may use the same port.

  # NOTE: If using NLB, then corresponding changes will be required to the 80-post-start.sh script to export port 6360,
  # 6361, etc. on each server in a region. Since we have VPC peering in Ping Cloud, all servers can use the same LDAPS
  # port, i.e. 1636, so we don't expose 636${ORDINAL} anymore.

  if is_multi_cluster; then
    export MULTI_CLUSTER=true
    is_primary_cluster &&
      export PRIMARY_CLUSTER=true ||
      export PRIMARY_CLUSTER=false

    # NLB settings:
    # export PD_HTTPS_PORT="443"
    # export PD_LDAP_PORT="389${ORDINAL}"
    # export PD_LDAPS_PORT="636${ORDINAL}"
    # export PD_REPL_PORT="989${ORDINAL}"

    # VPC peer settings (same as single-region case):
    export PD_HTTPS_PORT="${HTTPS_PORT}"
    export PD_LDAP_PORT="${LDAP_PORT}"
    export PD_LDAPS_PORT="${LDAPS_PORT}"
    export PD_REPL_PORT="${REPLICATION_PORT}"

    export PD_CLUSTER_DOMAIN_NAME="${PD_CLUSTER_PUBLIC_HOSTNAME}"
  else
    export MULTI_CLUSTER=false
    export PRIMARY_CLUSTER=true

    export PD_HTTPS_PORT="${HTTPS_PORT}"
    export PD_LDAP_PORT="${LDAP_PORT}"
    export PD_LDAPS_PORT="${LDAPS_PORT}"
    export PD_REPL_PORT="${REPLICATION_PORT}"

    export PD_CLUSTER_DOMAIN_NAME="${LOCAL_DOMAIN_NAME}"
  fi

  export PD_SEED_LDAP_HOST="${K8S_STATEFUL_SET_NAME}-0.${PD_CLUSTER_DOMAIN_NAME}"
  export LOCAL_HOST_NAME="${K8S_STATEFUL_SET_NAME}-${ORDINAL}.${PD_CLUSTER_DOMAIN_NAME}"
  export LOCAL_INSTANCE_NAME="${K8S_STATEFUL_SET_NAME}-${ORDINAL}-${REGION_NICK_NAME}"

  # Figure out the list of DNs to initialize replication on
  DN_LIST=
  if test -z "${REPLICATION_BASE_DNS}"; then
    DN_LIST="${USER_BASE_DN}"
  else
    echo "${REPLICATION_BASE_DNS}" | grep -q "${USER_BASE_DN}"
    test $? -eq 0 &&
        DN_LIST="${REPLICATION_BASE_DNS}" ||
        DN_LIST="${REPLICATION_BASE_DNS};${USER_BASE_DN}"
  fi

  export DNS_TO_ENABLE=$(echo "${DN_LIST}" | tr ';' ' ')
  export REPL_INIT_MARKER_FILE="${SERVER_ROOT_DIR}"/config/repl-initialized
  export POST_START_INIT_MARKER_FILE="${SERVER_ROOT_DIR}"/config/post-start-init-complete

  export UNINITIALIZED_DNS=
  for DN in ${DNS_TO_ENABLE}; do
    if ! grep -q "${DN}" "${REPL_INIT_MARKER_FILE}" &> /dev/null; then
      test -z "${UNINITIALIZED_DNS}" &&
          export UNINITIALIZED_DNS="${DN}" ||
          export UNINITIALIZED_DNS="${UNINITIALIZED_DNS} ${DN}"
    fi
  done

  beluga_log "MULTI_CLUSTER - ${MULTI_CLUSTER}"
  beluga_log "PRIMARY_CLUSTER - ${PRIMARY_CLUSTER}"
  beluga_log "PD_HTTPS_PORT - ${PD_HTTPS_PORT}"
  beluga_log "PD_LDAP_PORT - ${PD_LDAP_PORT}"
  beluga_log "PD_LDAPS_PORT - ${PD_LDAPS_PORT}"
  beluga_log "PD_REPL_PORT - ${PD_REPL_PORT}"
  beluga_log "PD_CLUSTER_DOMAIN_NAME - ${PD_CLUSTER_DOMAIN_NAME}"
  beluga_log "PD_SEED_LDAP_HOST - ${PD_SEED_LDAP_HOST}"
  beluga_log "LOCAL_HOST_NAME - ${LOCAL_HOST_NAME}"
  beluga_log "LOCAL_INSTANCE_NAME - ${LOCAL_INSTANCE_NAME}"
  beluga_log "DNS_TO_ENABLE - ${DNS_TO_ENABLE}"
  beluga_log "UNINITIALIZED_DNS - ${UNINITIALIZED_DNS}"
}

########################################################################################################################
# Determines if the environment is running in the context of multiple clusters.
#
# Returns
#   true if multi-cluster; false if not.
########################################################################################################################
function is_multi_cluster() {
  test ! -z "${IS_MULTI_CLUSTER}" && "${IS_MULTI_CLUSTER}"
}

########################################################################################################################
# Determines if the environment is set up in the primary cluster.
#
# Returns
#   true if primary cluster; false if not.
########################################################################################################################
function is_primary_cluster() {
  test "${TENANT_DOMAIN}" = "${PRIMARY_TENANT_DOMAIN}"
}

########################################################################################################################
# Determines if the environment is set up in a secondary cluster.
#
# Returns
#   true if secondary cluster; false if not.
########################################################################################################################
function is_secondary_cluster() {
  ! is_primary_cluster
}

########################################################################################################################
# Logs the provided message at the provided log level. Default log level is INFO, if not provided.
#
# Arguments
#   $1 -> The log message.
#   $2 -> Optional log level. Default is INFO.
########################################################################################################################
function beluga_log() {
  file_name="$(basename "$0")"
  message="$1"
  test -z "$2" && log_level='INFO' || log_level="$2"
  format='+%Y-%m-%d %H:%M:%S'
  timestamp="$(TZ=UTC date "${format}")"
  echo "${file_name}: ${timestamp} ${log_level} ${message}"
}

########################################################################################################################
# Logs the provided message and set the log level to ERROR.
#
# Arguments
#   $1 -> The log message.
########################################################################################################################
function beluga_error() {
  beluga_log "$1" 'ERROR'
}

########################################################################################################################
# Logs the provided message and set the log level to WARN.
#
# Arguments
#   $1 -> The log message.
########################################################################################################################
function beluga_warn() {
  beluga_log "$1" 'WARN'
}

########################################################################################################################
# Get LDIF for the base entry of USER_BASE_DN and return the LDIF file as stdout
########################################################################################################################
get_base_entry_ldif() {
  COMPUTED_DOMAIN=$(echo "${USER_BASE_DN}" | sed 's/^dc=\([^,]*\).*/\1/')
  COMPUTED_ORG=$(echo "${USER_BASE_DN}" | sed 's/^o=\([^,]*\).*/\1/')

  USER_BASE_ENTRY_LDIF=$(mktemp)

  if ! test "${USER_BASE_DN}" = "${COMPUTED_DOMAIN}"; then
    cat > "${USER_BASE_ENTRY_LDIF}" <<EOF
dn: ${USER_BASE_DN}
objectClass: top
objectClass: domain
dc: ${COMPUTED_DOMAIN}
EOF
  elif ! test "${USER_BASE_DN}" = "${COMPUTED_ORG}"; then
    cat > "${USER_BASE_ENTRY_LDIF}" <<EOF
dn: ${USER_BASE_DN}
objectClass: top
objectClass: organization
o: ${COMPUTED_DOMAIN}
EOF
  else
    beluga_log "User base DN must be 1-level deep in one of these formats: dc=<domain>,dc=com or o=<org>,dc=com"
    return 80
  fi

  # Append some required ACIs to the base entry file. Without these, PF SSO will not work.
  cat >> "${USER_BASE_ENTRY_LDIF}" <<EOF
aci: (targetattr!="userPassword")(version 3.0; acl "Allow read access for all"; allow (read,search,compare) userdn="ldap:///all";)
aci: (targetattr!="userPassword")(version 3.0; acl "Allow self-read access to all user attributes except the password"; allow (read,search,compare) userdn="ldap:///self";)
aci: (targetattr="*")(version 3.0; acl "Allow users to update their own entries"; allow (write) userdn="ldap:///self";)
aci: (targetattr="*")(version 3.0; acl "Grant full access for the admin user"; allow (all) userdn="ldap:///uid=admin,${USER_BASE_DN}";)
EOF

  echo "${USER_BASE_ENTRY_LDIF}"
}

########################################################################################################################
# Add the base entry of USER_BASE_DN if it needs to be added
########################################################################################################################
add_base_entry_if_needed() {
  num_user_entries=$(dbtest list-entry-containers --backendID "${USER_BACKEND_ID}" 2>/dev/null |
    grep -i "${USER_BASE_DN}" | awk '{ print $4; }')
  beluga_log "Number of sub entries of DN ${USER_BASE_DN} in ${USER_BACKEND_ID} backend: ${num_user_entries}"

  if test "${num_user_entries}" && test "${num_user_entries}" -gt 0; then
    beluga_log "Replication base DN ${USER_BASE_DN} already added"
    return 0
  else
    base_entry_ldif=$(get_base_entry_ldif)
    get_entry_status=$?
    beluga_log "get user base entry status: ${get_entry_status}"
    test ${get_entry_status} -ne 0 && return ${get_entry_status}

    beluga_log "Adding replication base DN ${USER_BASE_DN} with contents:"
    cat "${base_entry_ldif}"

    import-ldif -n "${USER_BACKEND_ID}" -l "${base_entry_ldif}" \
        --includeBranch "${USER_BASE_DN}" --overwriteExistingEntries
    import_status=$?
    beluga_log "import user base entry status: ${import_status}"
    return ${import_status}
  fi
}

########################################################################################################################
# Enable the replication sub-system in offline mode.
########################################################################################################################
offline_enable_replication() {
  # The userRoot backend must be configured for the user base DN, if it changed
  # between restart of the container.
  beluga_log "configuring ${USER_BACKEND_ID} for base DN ${USER_BASE_DN}"
  dsconfig --no-prompt --offline set-backend-prop \
    --backend-name "${USER_BACKEND_ID}" \
    --add "base-dn:${USER_BASE_DN}" \
    --set enabled:true \
    --set db-cache-percent:35 \
    --set import-thread-count:1
  config_status=$?
  beluga_log "configure base DN ${USER_BASE_DN} update status: ${config_status}"
  test ${config_status} -ne 0 && return ${config_status}

  # Replicated base DNs must exist before starting the server now that
  # replication is enabled before start. Otherwise a generation ID of -1
  # would be generated, which breaks replication.
  add_base_entry_if_needed
  add_base_entry_status=$?
  beluga_log "add base DN ${USER_BASE_DN} status: ${add_base_entry_status}"
  test ${add_base_entry_status} -ne 0 && return ${add_base_entry_status}

  # Enable replication offline.
  "${HOOKS_DIR}"/185-offline-enable-wrapper.sh
  enable_status=$?
  beluga_log "offline replication enable status: ${enable_status}"
  test ${enable_status} -ne 0 && return ${enable_status}

  return 0
}

# These are needed by every script - so export them when this script is sourced.
beluga_log "export config settings"
export_config_settings
