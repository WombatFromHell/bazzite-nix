#!/usr/bin/env bash
#==============================================================================
# distrobox-installer.sh - Shared helper for distrobox-based installer scripts
#
# Provides common utilities for container lifecycle, export management,
# and CLI argument parsing.
#
# Usage: source this file from a wrapper script.
# The wrapper MUST define required config and call dbx_main.
#
# CONFIGURATION (required):
#   readonly CONTAINER_NAME="..."        # Container name (required)
#   readonly DBX_EXPORT_APP="..."       # App to export (required)
#
# CONFIGURATION (optional):
#   readonly CONTAINER_IMAGE="${CONTAINER_IMAGE:-fedora:43}"
#   readonly DBX_USE_ROOT="${DBX_USE_ROOT:-false}"
#   readonly DBX_INIT="${DBX_INIT:-}"              # systemd, openrc, etc.
#   readonly DBX_PACKAGES="${DBX_PACKAGES:-}"       # Space/comma-separated
#   readonly DBX_FLAGS="${DBX_FLAGS:-}"             # Additional distrobox flags
#   readonly DBX_INIT_HOOKS=()     # Array: commands run during init
#   readonly DBX_POST_HOOKS=()     # Array: commands run after creation
#   readonly DBX_UNSHARE_ALL="${DBX_UNSHARE_ALL:-false}"
#
# CALLBACKS (optional):
#   DBX_PRE_CREATE_HOOK=""   # Function name to run before container creation
#   DBX_POST_CREATE_HOOK=""  # Function name to run after container creation
#   DBX_PRE_EXPORT_HOOK=""    # Function name to run before export
#   DBX_POST_EXPORT_HOOK=""   # Function name to run after export
#
# Exported functions (all prefixed with dbx_):
#   dbx_log, dbx_err              - Logging utilities
#   dbx_is_inside_container       - Check if running inside a container
#   dbx_container_exists          - Check if a container exists
#   dbx_is_exported             - Check if an app is exported
#   dbx_get_container_prefix    - Get container ID or name for desktop files
#   dbxe                        - Shortcut for distrobox-enter
#   dbx_needs_sudo              - Check if sudo is needed for podman
#   dbx_get_podman_cmd         - Get podman command (with sudo if needed)
#   dbx_remove_container       - Remove container (distrobox + podman)
#   dbx_assemble_container     - Create container using INI format
#   dbx_do_export            - Export an application to host
#   dbx_do_uninstall         - Remove export from host
#   dbx_do_remove            - Remove export + container
#   dbx_cleanup_desktop_files - Clean up old desktop files
#   dbx_parse_args          - Parse CLI arguments (sets ACTION etc.)
#   dbx_show_help           - Print help and exit
#   dbx_confirm             - Prompt for confirmation
#   dbx_main               - Standard main() pattern (USES GLOBALS)
#   dbx_ensure_container   - Ensure container exists (USES GLOBALS)
#   dbx_ensure_exported    - Ensure app is exported (USES GLOBALS)
#   dbx_freshen            - Re-run post-hooks, refresh export (USES GLOBALS)
#   dbx_check_app_installed - Check if app is installed in container (USES DBX_CHECK_APP)
#==============================================================================
set -euo pipefail

#------------------------------------------------------------------------------
# CONFIGURATION (defaults - callers must override)
#------------------------------------------------------------------------------

DBX_USE_ROOT="${DBX_USE_ROOT:-false}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-fedora:43}"
DBX_INIT="${DBX_INIT:-}"
DBX_PACKAGES="${DBX_PACKAGES:-}"
DBX_FLAGS="${DBX_FLAGS:-}"
DBX_UNSHARE_ALL="${DBX_UNSHARE_ALL:-false}"
DBX_CHECK_APP="${DBX_CHECK_APP:-}"
DBX_INIT_HOOKS=("${DBX_INIT_HOOKS[@]:-}")
DBX_POST_HOOKS=("${DBX_POST_HOOKS[@]:-}")
DBX_POST_CREATE_HOOK="${DBX_POST_CREATE_HOOK:-}"

# Auto-register check hook if DBX_CHECK_APP is set
if [[ -n "$DBX_CHECK_APP" && -z "$DBX_POST_CREATE_HOOK" ]]; then
  DBX_POST_CREATE_HOOK="dbx_check_app_installed"
fi

#------------------------------------------------------------------------------
# CORE UTILITIES
#------------------------------------------------------------------------------

dbx_log() { printf "\e[1;34m>>\e[0m %s\n" "$@"; }
dbx_err() { printf "\e[1;31m!!\e[0m %s\n" "$@" >&2; }

dbx_is_inside_container() { [[ -f /var/run/.containerenv ]]; }

dbx_needs_sudo() {
  local use_root="${1:-${DBX_USE_ROOT:-false}}"

  [[ $EUID -eq 0 ]] && return 1
  [[ "$use_root" == "true" ]] && return 0

  if [[ -n "${DBX_SUDO:-}" ]]; then
    [[ "$DBX_SUDO" == "true" ]] && return 0
    return 1
  fi

  sudo -n podman ps &>/dev/null && return 0
  return 1
}

dbx_get_podman_cmd() {
  local use_root="${1:-${DBX_USE_ROOT:-false}}"
  if dbx_needs_sudo "$use_root"; then
    echo "sudo podman"
  else
    echo "podman"
  fi
}

dbx_container_exists() {
  local name="${1:-${CONTAINER_NAME:-}}"
  local use_root="${2:-${DBX_USE_ROOT:-false}}"
  local list_flags=""
  local podman_cmd
  [[ "$use_root" == "true" ]] && list_flags="--root"
  podman_cmd=$(dbx_get_podman_cmd "$use_root")

  distrobox list $list_flags 2>/dev/null | tail -n +2 | grep -qE "\|\s+${name}\s+\|" ||
    distrobox list $list_flags 2>/dev/null | grep -qw "${name}"
}

dbx_is_exported() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  local app_id="$2"
  local desktop_file="$HOME/.local/share/applications/${container_name}-${app_id}.desktop"
  [[ -f "$desktop_file" ]]
}

dbxe() {
  local use_root="${DBX_USE_ROOT:-false}"
  local container_name
  local -a cmd=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --root)
      use_root="true"
      shift
      ;;
    --name)
      container_name="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      # If we haven't seen -- or --name yet, this might be the container name (positional)
      if [[ -z "$container_name" && -z "${cmd[*]:-}" ]]; then
        container_name="$1"
        shift
      else
        # Otherwise collect as command
        cmd+=("$1")
        shift
      fi
      ;;
    esac
  done

  # Second pass: collect remaining as command arguments
  while [[ $# -gt 0 ]]; do
    cmd+=("$1")
    shift
  done

  container_name="${container_name:-${CONTAINER_NAME:-}}"

  if [[ -z "$container_name" ]]; then
    dbx_err "dbxe: CONTAINER_NAME not set"
    return 1
  fi

  local root_flag=()
  [[ "$use_root" == "true" ]] && root_flag=("--root")
  distrobox-enter "${root_flag[@]}" "${container_name}" -- "${cmd[@]}"
}

dbx_get_container_prefix() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  if dbx_is_inside_container; then
    # shellcheck disable=SC1091
    source /var/run/.containerenv 2>/dev/null || true
    echo "${CONTAINER_ID:-}"
  else
    echo "$container_name"
  fi
}

#------------------------------------------------------------------------------
# CONTAINER MANAGEMENT
#------------------------------------------------------------------------------

dbx_remove_container() {
  local name="${1:-${CONTAINER_NAME:-}}"
  local use_root="${2:-${DBX_USE_ROOT:-false}}"
  local -a root_flag=()
  local podman_cmd

  [[ "$use_root" == "true" ]] && root_flag=("--root")
  podman_cmd=$(dbx_get_podman_cmd "$use_root")

  # No-op if already gone
  if ! $podman_cmd ps -a --format "{{.Names}}" 2>/dev/null | grep -qw "${name}" &&
    ! distrobox list "${root_flag[@]}" 2>/dev/null | grep -qw "${name}"; then
    return 0
  fi

  dbx_log "Removing container '${name}'..."
  $podman_cmd kill "${name}" 2>/dev/null || true
  $podman_cmd rm -f "${name}" 2>/dev/null || true
  distrobox rm -f "${root_flag[@]}" "${name}" 2>/dev/null || true
  $podman_cmd container prune -f 2>/dev/null || true
}

# shellcheck disable=SC2120,SC2119
dbx_assemble_container() {
  local name="${CONTAINER_NAME:-}"
  local image="${CONTAINER_IMAGE:-fedora:43}"
  local use_root="${DBX_USE_ROOT:-false}"
  local packages="${DBX_PACKAGES:-}"
  local init_pkg="${DBX_INIT:-}"
  local additional_flags=()
  local init_hooks=("${DBX_INIT_HOOKS[@]}")
  local post_hooks=("${DBX_POST_HOOKS[@]}")
  local exported_apps=""
  local unshare_flags=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --name)
      name="$2"
      shift 2
      ;;
    --image)
      image="$2"
      shift 2
      ;;
    --root)
      use_root="true"
      shift
      ;;
    --packages)
      packages="$2"
      shift 2
      ;;
    --init)
      init_pkg="$2"
      shift 2
      ;;
    --flags)
      additional_flags+=("$2")
      shift 2
      ;;
    --hooks-array)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        [[ -n "$1" ]] && init_hooks+=("$1")
        shift
      done
      ;;
    --post-hooks-array)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        [[ -n "$1" ]] && post_hooks+=("$1")
        shift
      done
      ;;
    --exports)
      exported_apps="$2"
      shift 2
      ;;
    --unshare-all)
      unshare_flags+=("all=true")
      shift
      ;;
    --unshare-*)
      unshare_flags+=("${1#--unshare-}=true")
      shift
      ;;
    --)
      shift
      break
      ;;
    --*) shift ;;
    esac
  done

  if [[ -z "$name" ]]; then
    dbx_err "dbx_assemble_container: CONTAINER_NAME not set"
    return 1
  fi
  if [[ -z "$image" ]]; then
    dbx_err "dbx_assemble_container: CONTAINER_IMAGE not set"
    return 1
  fi

  dbx_remove_container "$name" "$use_root"
  dbx_log "Creating container '${name}' with ${image}..."

  local ini_root_flag=""
  [[ "$use_root" == "true" ]] && ini_root_flag="root=true"
  [[ "$DBX_UNSHARE_ALL" == "true" ]] && unshare_flags+=("all=true")

  local flags_str="${additional_flags[*]:-${DBX_FLAGS:-}}"

  local assemble_file
  assemble_file=$(mktemp)
  trap 'rm -f "${assemble_file:-}"' RETURN

  dbx_log "Generating assemble configuration..."

  {
    printf '%s\n' "[${name}]"
    printf '%s=%s\n' "image" "${image}"
    printf '%s=%s\n' "pull" "true"
    [[ -n "$init_pkg" ]] && printf '%s=%s\n' "init" "true"
    printf '%s=%s\n' "start_now" "true"
    [[ -n "$ini_root_flag" ]] && printf '%s\n' "$ini_root_flag"
    for unshare in "${unshare_flags[@]}"; do
      [[ -n "$unshare" ]] || continue
      printf '%s=%s\n' "unshare_${unshare%=*}" "${unshare#*=}"
    done
    local combined_packages="$packages"
    [[ -n "$init_pkg" && -n "$packages" ]] && combined_packages="${init_pkg} ${packages}"
    [[ -n "$init_pkg" && -z "$packages" ]] && combined_packages="$init_pkg"
    [[ -n "$combined_packages" ]] && printf '%s="%s"\n' "additional_packages" "${combined_packages}"
    [[ -n "$flags_str" ]] && printf '%s="%s"\n' "additional_flags" "${flags_str}"
    for hook in "${init_hooks[@]}"; do
      [[ -n "$hook" ]] && printf '%s="%s"\n' "init_hooks" "${hook}"
    done
    [[ -n "$exported_apps" ]] && printf '%s="%s"\n' "exported_apps" "${exported_apps}"
  } >"${assemble_file}"

  if [ -n "${DEBUG:-}" ]; then
    echo "--- START ASSEMBLE INI ---"
    cat "${assemble_file}"
    echo "--- END ASSEMBLE INI ---"
  fi

  dbx_log "Assembling container..."
  distrobox assemble create --file "${assemble_file}" --replace 2>&1 || true
  if dbx_container_exists "$name" "$use_root"; then
    dbx_log "Container '${name}' created successfully."
  else
    dbx_err "Failed to create container '${name}'."
    return 1
  fi

  if [[ ${#post_hooks[@]} -gt 0 ]]; then
    dbx_log "Running post-hooks..."

    local hook_script
    hook_script=$(mktemp)
    trap 'rm -f "${hook_script:-}"' RETURN

    {
      printf '#!/usr/bin/env bash\n'
      printf 'set -euo pipefail\n'
      for hook in "${post_hooks[@]}"; do
        printf '%s\n' "$hook"
      done
    } >"${hook_script}"

    if [ -n "${DEBUG:-}" ]; then
      echo "--- START POST-HOOKS SCRIPT ---"
      cat "${hook_script}"
      echo "--- END POST-HOOKS SCRIPT ---"
    fi

    dbx_log "Executing post-hooks script..."
    if ! dbxe --name "${name}" bash -x "${hook_script}"; then
      dbx_err "Post-hooks failed (continuing anyway)"
    fi
  fi
}

#------------------------------------------------------------------------------
# EXPORT MANAGEMENT
#------------------------------------------------------------------------------

dbx_do_export() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  local export_app="${2:-${DBX_EXPORT_APP:-}}"
  local use_root="${3:-${DBX_USE_ROOT:-false}}"

  [[ -z "$export_app" ]] && dbx_err "dbx_do_export: DBX_EXPORT_APP not set" && return 1

  dbx_log "Exporting ${export_app}..."

  if dbxe --name "${container_name}" -- distrobox-export -a "${export_app}" 2>&1; then
    dbx_log "Export successful."
  else
    if dbx_is_exported "$container_name" "$export_app"; then
      dbx_log "Export successful (verified)."
    else
      dbx_err "Export failed."
      return 1
    fi
  fi
}

dbx_do_uninstall() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  local export_app="${2:-${DBX_EXPORT_APP:-}}"
  local use_root="${3:-${DBX_USE_ROOT:-false}}"

  [[ -z "$export_app" ]] && dbx_err "dbx_do_uninstall: DBX_EXPORT_APP not set" && return 1

  dbx_log "Removing ${export_app} export..."

  if dbx_container_exists "$container_name" "$use_root"; then
    dbxe --name "${container_name}" -- distrobox-export -d -a "${export_app}" 2>/dev/null || true
  fi

  rm -f "$HOME/.local/share/applications/${container_name}-${export_app}.desktop" 2>/dev/null || true
  rm -f "$HOME/.local/share/applications/${container_name}-${export_app}.desktop.bak" 2>/dev/null || true

  dbx_log "Uninstall complete. Run with --install to reinstall."
}

dbx_do_remove() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  local export_app="${2:-${DBX_EXPORT_APP:-}}"
  local use_root="${3:-${DBX_USE_ROOT:-false}}"

  [[ -z "$export_app" ]] && dbx_err "dbx_do_remove: DBX_EXPORT_APP not set" && return 1

  if ! dbx_confirm "This will remove the '${container_name}' container and all its data. This action cannot be undone."; then
    dbx_log "Removal cancelled."
    return 0
  fi

  dbx_log "Removing container and exports..."

  if dbx_container_exists "$container_name" "$use_root"; then
    dbxe --name "${container_name}" -- distrobox-export -d -a "${export_app}" 2>/dev/null || true
  fi

  dbx_remove_container "$container_name" "$use_root"
  dbx_cleanup_desktop_files "$container_name"

  dbx_log "Removal complete."
}

dbx_cleanup_desktop_files() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  local apps_dir="$HOME/.local/share/applications"
  local found=false

  for f in "${apps_dir}/${container_name}"-*.desktop \
    "${apps_dir}/${container_name}"-*.desktop.bak; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "${container_name}.desktop" ]] && continue
    found=true
    break
  done

  [[ "$found" == "false" ]] && return 0

  dbx_log "Cleaning up old desktop files..."
  for f in "${apps_dir}/${container_name}"-*.desktop \
    "${apps_dir}/${container_name}"-*.desktop.bak; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "${container_name}.desktop" ]] && continue
    rm -f "$f"
  done
  update-desktop-database "${apps_dir}" 2>/dev/null || true
}

#------------------------------------------------------------------------------
# ARGUMENT PARSING
#------------------------------------------------------------------------------

dbx_parse_args() {
  ACTION="${ACTION:-default}"
  INSTALL_TYPE="${INSTALL_TYPE:-}"
  RM_CONTAINER="${RM_CONTAINER:-false}"
  RECREATE="${RECREATE:-false}"
  FRESHEN="${FRESHEN:-false}"
  YES="${YES:-false}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -y | --yes)
      YES="true"
      shift
      ;;
    --recreate)
      ACTION="recreate"
      RECREATE="true"
      shift
      ;;
    --freshen | --upgrade)
      ACTION="freshen"
      FRESHEN="true"
      shift
      ;;
    --install | --uninstall)
      [[ "$1" == "--install" ]] && ACTION="install" || ACTION="uninstall"
      shift
      if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
        INSTALL_TYPE="$1"
        shift
      fi
      ;;
    --rm)
      RM_CONTAINER="true"
      shift
      ;;
    --help)
      return 0
      ;;
    *)
      dbx_err "Unknown argument: $1"
      return 1
      ;;
    esac
  done
  return 2
}

dbx_show_help() {
  local script_name="$1"
  local help_text="$2"
  printf "Usage: %s [OPTIONS]\n\n%s\n" "${script_name##*/}" "$help_text"
  exit 0
}

dbx_confirm() {
  local message="$1"
  local response=""
  if [[ "$YES" == "true" ]]; then
    return 0
  fi
  dbx_err "$message"
  read -rp "Proceed? [y/N] " response
  case "$response" in
  [yY] | [yY][eE][sS]) return 0 ;;
  *) return 1 ;;
  esac
}

#------------------------------------------------------------------------------
# HIGHER-LEVEL HELPERS (USE GLOBALS)
#------------------------------------------------------------------------------

# Run the pre-create hook if defined
dbx_run_pre_create_hook() {
  if [[ -n "${DBX_PRE_CREATE_HOOK:-}" ]]; then
    type "$DBX_PRE_CREATE_HOOK" &>/dev/null && "$DBX_PRE_CREATE_HOOK"
  fi
}

# Run the post-create hook if defined
dbx_run_post_create_hook() {
  if [[ -n "${DBX_POST_CREATE_HOOK:-}" ]]; then
    type "$DBX_POST_CREATE_HOOK" &>/dev/null && "$DBX_POST_CREATE_HOOK"
  fi
}

# Check if app is installed in container
# Usage: dbx_check_app_installed (uses DBX_CHECK_APP global)
dbx_check_app_installed() {
  local check_app="${DBX_CHECK_APP:-}"
  local use_root="${DBX_USE_ROOT:-false}"

  [[ -z "$check_app" ]] && return 0

  # Check if dbxe is available (outer script context) vs inside container
  if type dbxe &>/dev/null; then
    if ! dbxe -- which "$check_app" &>/dev/null; then
      dbx_err "${check_app} not found in container. Run with --recreate to reinstall."
      return 1
    fi
  else
    if ! which "$check_app" &>/dev/null; then
      echo "${check_app} not found in container."
      return 1
    fi
  fi

  return 0
}

# Run the pre-export hook if defined
dbx_run_pre_export_hook() {
  local hook="${DBX_PRE_EXPORT_HOOK:-}"
  [[ -n "$hook" ]] && type "$hook" &>/dev/null && "$hook"
}

# Run the post-export hook if defined
dbx_run_post_export_hook() {
  local hook="${DBX_POST_EXPORT_HOOK:-}"
  [[ -n "$hook" ]] && type "$hook" &>/dev/null && "$hook"
}

# Ensure container exists, create if missing
# Usage: dbx_ensure_container [recreate]
dbx_ensure_container() {
  local recreate="${1:-${RECREATE:-false}}"
  local use_root="${DBX_USE_ROOT:-false}"
  local container_name="${CONTAINER_NAME:-}"

  [[ -z "$container_name" ]] && dbx_err "dbx_ensure_container: CONTAINER_NAME not set" && return 1

  if [[ "$recreate" == "true" ]]; then
    if dbx_container_exists "$container_name" "$use_root"; then
      if ! dbx_confirm "This will recreate the '${container_name}' container. All existing data and exports will be lost."; then
        dbx_log "Recreation cancelled."
        return 1
      fi
    fi
    dbx_log "Recreating container..."
    dbx_remove_container "$container_name" "$use_root"
    dbx_cleanup_desktop_files "$container_name"
  elif dbx_container_exists "$container_name" "$use_root"; then
    dbx_log "Container '${container_name}' exists."
  else
    dbx_log "Container not found. Creating..."
  fi

  if [[ "$recreate" == "true" ]] || ! dbx_container_exists "$container_name" "$use_root"; then
    dbx_run_pre_create_hook
    dbx_assemble_container
    dbx_run_post_create_hook
  fi
}

# Ensure app is exported, export if missing
# Usage: dbx_ensure_exported [export_app]
dbx_ensure_exported() {
  local export_app="${1:-${DBX_EXPORT_APP:-}}"
  local use_root="${DBX_USE_ROOT:-false}"
  local container_name="${CONTAINER_NAME:-}"

  [[ -z "$export_app" ]] && dbx_err "dbx_ensure_exported: DBX_EXPORT_APP not set" && return 1

  if dbx_is_exported "$container_name" "$export_app"; then
    dbx_log "${export_app} already exported."
    return 0
  fi

  dbx_run_pre_export_hook
  dbx_do_export "$container_name" "$export_app" "$use_root"
  dbx_run_post_export_hook
}

# Freshen: re-run post-hooks and re-export (for package updates)
# Usage: dbx_freshen
dbx_freshen() {
  local container_name="${CONTAINER_NAME:-}"
  local use_root="${DBX_USE_ROOT:-false}"
  local export_app="${DBX_EXPORT_APP:-}"

  [[ -z "$container_name" ]] && dbx_err "dbx_freshen: CONTAINER_NAME not set" && return 1
  [[ -z "$export_app" ]] && dbx_err "dbx_freshen: DBX_EXPORT_APP not set" && return 1
  [[ "$use_root" == "true" ]] && use_root="--root " || use_root=""

  dbx_log "Freshening container '${container_name}'..."

  # Re-run post-hooks if any are defined
  if [[ ${#DBX_POST_HOOKS[@]} -gt 0 ]]; then
    local hook_script
    hook_script=$(mktemp)
    trap 'rm -f "${hook_script:-}"' RETURN

    {
      printf '#!/usr/bin/env bash\n'
      printf 'set -euo pipefail\n'
      for hook in "${DBX_POST_HOOKS[@]}"; do
        printf '%s\n' "$hook"
      done
    } >"${hook_script}"

    dbx_log "Executing post-hooks script..."
    dbxe --name "${container_name}" bash -x "${hook_script}" || true
  fi

  # Re-export the app
  dbx_ensure_exported "$export_app"
  dbx_log "Freshen complete."
}

# Standard main() pattern - uses globals
# Usage: dbx_main [help_text] [args...]
dbx_main() {
  local help_text="${1:-}"
  shift
  local cli_args=("$@")

  if dbx_is_inside_container; then
    exit 0
  fi

  local parse_result=0
  dbx_parse_args "${cli_args[@]}" || parse_result=$?

  if [[ $parse_result -ne 2 ]]; then
    dbx_show_help "$0" "$help_text"
  fi

  local use_root="${DBX_USE_ROOT:-false}"
  local container_name="${CONTAINER_NAME:-}"
  local export_app="${DBX_EXPORT_APP:-}"

  if [[ -z "$container_name" ]]; then
    dbx_err "CONTAINER_NAME not set"
    exit 1
  fi
  if [[ -z "$export_app" ]]; then
    dbx_err "DBX_EXPORT_APP not set"
    exit 1
  fi

  case "$ACTION" in
  uninstall)
    if [[ "$RM_CONTAINER" == "true" ]]; then
      dbx_do_remove "$container_name" "$export_app" "$use_root"
    else
      dbx_do_uninstall "$container_name" "$export_app" "$use_root"
    fi
    exit 0
    ;;
  install)
    if [[ "$RECREATE" == "true" ]]; then
      if dbx_container_exists "$container_name" "$use_root"; then
        if ! dbx_confirm "This will recreate the '${container_name}' container. All existing data and exports will be lost."; then
          dbx_log "Recreation cancelled."
          exit 0
        fi
      fi
      dbx_remove_container "$container_name" "$use_root"
      dbx_cleanup_desktop_files "$container_name"
      dbx_ensure_container
    elif ! dbx_container_exists "$container_name" "$use_root"; then
      dbx_ensure_container
    fi
    dbx_ensure_exported "$export_app"
    dbx_log "Installation complete."
    ;;
  recreate)
    if dbx_container_exists "$container_name" "$use_root"; then
      if ! dbx_confirm "This will recreate the '${container_name}' container. All existing data and exports will be lost."; then
        dbx_log "Recreation cancelled."
        exit 0
      fi
    fi
    dbx_log "Recreating container..."
    dbx_remove_container "$container_name" "$use_root"
    dbx_cleanup_desktop_files "$container_name"
    dbx_ensure_container
    dbx_ensure_exported "$export_app"
    dbx_log "Installation complete."
    ;;
  freshen)
    if ! dbx_container_exists "$container_name" "$use_root"; then
      dbx_err "Container '${container_name}' does not exist. Cannot freshen."
      exit 1
    fi
    dbx_freshen
    dbx_log "Freshen complete."
    ;;
  default)
    if dbx_container_exists "$container_name" "$use_root"; then
      dbx_log "Container '${container_name}' exists."
    else
      dbx_log "Container not found. Creating..."
      dbx_ensure_container
    fi

    if ! dbx_is_exported "$container_name" "$export_app"; then
      dbx_ensure_exported "$export_app"
    fi
    dbx_log "Installation complete."
    ;;
  esac
}
