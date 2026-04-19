#!/usr/bin/env bash
#==============================================================================
# distrobox-installer.sh - Shared helper for distrobox-based installer scripts
#
# Provides common utilities for container lifecycle, export management,
# and CLI argument parsing.
#
# Usage: source this file from a wrapper script.
# The wrapper should define its configuration and call the helper functions.
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
#   dbx_create_container      - Create a new container (legacy method)
#   dbx_assemble_container     - Create container using INI format
#   dbx_do_export            - Export an application to host
#   dbx_do_uninstall         - Remove export from host
#   dbx_do_remove            - Remove export + container
#   dbx_cleanup_desktop_files - Clean up old desktop files
#   dbx_cleanup_exported_desktop_files - Clean up distrobox-export artifacts
#   dbx_create_xdg_bridge    - Create XDG open bridge for host integration
#   dbx_find_web_browser_desktop_files - Find web browser .desktop files
#   dbx_set_default_app      - Set default application
#   dbx_restore_default     - Restore previous default application
#   dbx_parse_args          - Parse CLI arguments (sets ACTION etc.)
#   dbx_show_help           - Print help and exit
#   dbx_confirm             - Prompt for confirmation
#   dbx_detect_wrapper       - Detect wrapper script (app-wrapper.sh or chromium-flags.sh)
#   dbx_build_exec_target    - Build Exec= target for desktop file
#   dbx_install_dnf         - Install package via DNF in container
#   dbx_configure_desktop_file - Configure desktop file with wrapper/exec target
#   dbx_cleanup_app_desktop_files - Clean up app-specific desktop files
#==============================================================================
set -euo pipefail

#------------------------------------------------------------------------------
# CORE UTILITIES
#------------------------------------------------------------------------------

dbx_log() { printf "\e[1;34m>>\e[0m %s\n" "$@"; }
dbx_err() { printf "\e[1;31m!!\e[0m %s\n" "$@" >&2; }

dbx_is_inside_container() { [[ -f /var/run/.containerenv ]]; }

# Auto-detect if sudo is needed for podman operations
# Checks: running as root, rootful container flag, and existing rootful containers
dbx_needs_sudo() {
  local use_root="${1:-false}"

  [[ $EUID -eq 0 ]] && return 1

  [[ "$use_root" == "true" ]] && return 0

  if [[ -n "${DBX_SUDO:-}" ]]; then
    [[ "$DBX_SUDO" == "true" ]] && return 0
    return 1
  fi

  if sudo -n podman ps &>/dev/null; then
    return 0
  fi

  return 1
}

# Get the proper podman command (with sudo if needed)
dbx_get_podman_cmd() {
  local use_root="${1:-false}"
  if dbx_needs_sudo "$use_root"; then
    echo "sudo podman"
  else
    echo "podman"
  fi
}

# Check if a container exists
# Usage: dbx_container_exists <name> [rootful]
dbx_container_exists() {
  local name="$1"
  local use_root="${2:-false}"
  local list_flags=""
  local podman_cmd
  [[ "$use_root" == "true" ]] && list_flags="--root"
  podman_cmd=$(dbx_get_podman_cmd "$use_root")

  distrobox list $list_flags 2>/dev/null | tail -n +2 | grep -qE "\|\s+${name}\s+\|" ||
    distrobox list $list_flags 2>/dev/null | grep -qw "${name}"
}

# Check if an app is exported (desktop file exists)
# Usage: dbx_is_exported <container_name> <app_id>
dbx_is_exported() {
  local container_name="$1"
  local app_id="$2"
  local desktop_file="$HOME/.local/share/applications/${container_name}-${app_id}.desktop"
  [[ -f "$desktop_file" ]]
}

# Shortcut for distrobox-enter commands
# Usage: dbxe <container_name> [rootful] -- <command> [args...]
# Or:    CONTAINER_NAME=xxx dbxe -- <command> [args...]
dbxe() {
  local container_name=""
  local use_root="false"

  # Parse: optional container name, optional --root flag, then --
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--root" ]]; then
      use_root="true"
      shift
    elif [[ "$1" == "--" ]]; then
      shift
      break
    else
      container_name="$1"
      shift
    fi
  done

  # Use CONTAINER_NAME env var if not specified
  container_name="${container_name:-${CONTAINER_NAME:-}}"
  if [[ -z "$container_name" ]]; then
    dbx_err "dbxe: CONTAINER_NAME not set"
    return 1
  fi

  if [[ "$use_root" == "true" ]]; then
    distrobox-enter --root "${container_name}" -- "$@"
  else
    distrobox-enter "${container_name}" -- "$@"
  fi
}

#------------------------------------------------------------------------------
# CONTAINER MANAGEMENT
#------------------------------------------------------------------------------

# Remove a container (podman first to handle corrupted state, then distrobox cleanup)
# Usage: dbx_remove_container <name> [rootful]
dbx_remove_container() {
  local name="$1"
  local use_root="${2:-false}"
  local root_flag=""
  local podman_cmd

  [[ "$use_root" == "true" ]] && root_flag="--root"
  podman_cmd=$(dbx_get_podman_cmd "$use_root")

  dbx_log "Removing container '${name}'..."

  # Use podman ps to check (more robust than 'podman container exists' for corrupted state)
  if $podman_cmd ps -a --format "{{.Names}}" 2>/dev/null | grep -qw "${name}"; then
    dbx_log "Removing container '${name}' via podman..."
    # Kill first in case it's running, then remove
    $podman_cmd kill "${name}" 2>/dev/null || true
    $podman_cmd rm -f "${name}" 2>/dev/null || true
  fi

  # Try distrobox rm as well (may fail if image is missing from store)
  distrobox rm -f ${root_flag} "${name}" 2>/dev/null || true

  # Final cleanup via podman in case distrobox left artifacts
  if $podman_cmd ps -a --format "{{.Names}}" 2>/dev/null | grep -qw "${name}"; then
    dbx_log "Force removing via podman..."
    $podman_cmd kill "${name}" 2>/dev/null || true
    $podman_cmd rm -f "${name}" 2>/dev/null || true
  fi

  # Unstage any stopped containers that may be lingering
  $podman_cmd container prune -f 2>/dev/null || true
}

# Create a new container
# Usage: dbx_create_container <name> <image> [rootful] [additional_flags...]
dbx_create_container() {
  local name="$1"
  local image="$2"
  local use_root="${3:-false}"

  dbx_remove_container "$name" "$use_root"
  dbx_log "Creating container '${name}' with ${image}..."

  local root_flag=""
  [[ "$use_root" == "true" ]] && root_flag="--root"

  # Remaining args are extra flags for distrobox create
  local extra_flags=("${@:3}")

  if [[ ${#extra_flags[@]} -gt 0 ]]; then
    distrobox create $root_flag -Y -i "${image}" --name "${name}" "${extra_flags[@]}"
  else
    distrobox create $root_flag -Y -i "${image}" --name "${name}"
  fi
}

# Create a container using distrobox-assemble INI format
# Usage: dbx_assemble_container --name <name> --image <image> [--root] [--packages <packages>] [--init <init_pkg>] [--flags <flags>] [--hooks <hooks>] [--hooks-array <hook1> <hook2>...] [--post-hooks <cmd1> <cmd2>...] [--exports <exports>] [--unshare-*]
# Example:
#   dbx_assemble_container --name "mybox" --image "fedora:43" --root --packages "vim,git" --flags "--volume /dev:/dev" --hooks "echo done" --exports "vim"
#   dbx_assemble_container --name "mybox" --image "fedora:43" --hooks-array "cmd1" "cmd2" "cmd3"
#   dbx_assemble_container --name "mybox" --image "fedora:43" --post-hooks "yay -Syu --noconfirm pkg" "yay -S --noconfirm pkg2"
#   dbx_assemble_container --name "mybox" --image "fedora:43" --init "systemd" --packages "vim,git"
dbx_assemble_container() {
  local name=""
  local image=""
  local use_root="false"
  local packages=""
  local init_pkg=""
  local additional_flags=()
  local init_hooks=()
  local post_hooks=()
  local exported_apps=""
  local unshare_flags=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --name)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        dbx_err "dbx_assemble_container: --name requires a value"
        return 1
      fi
      name="$2"
      shift 2
      ;;
    --image)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        dbx_err "dbx_assemble_container: --image requires a value"
        return 1
      fi
      image="$2"
      shift 2
      ;;
    --root)
      use_root="true"
      shift
      ;;
    --packages)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        dbx_err "dbx_assemble_container: --packages requires a value"
        return 1
      fi
      packages="$2"
      shift 2
      ;;
    --init)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        dbx_err "dbx_assemble_container: --init requires a value"
        return 1
      fi
      init_pkg="$2"
      shift 2
      ;;
    --flags)
      if [[ $# -lt 2 ]]; then
        dbx_err "dbx_assemble_container: --flags requires a value"
        return 1
      fi
      local flags_arg="$2"
      shift 2
      for flag in $flags_arg; do
        [[ -n "$flag" ]] && additional_flags+=("$flag")
      done
      ;;
    --hooks)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        dbx_err "dbx_assemble_container: --hooks requires a value"
        return 1
      fi
      init_hooks+=("$2")
      shift 2
      ;;
    --hooks-array)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        [[ -n "$1" ]] && init_hooks+=("$1")
        shift
      done
      ;;
    --post-hooks)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        [[ -n "$1" ]] && post_hooks+=("$1")
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
      if [[ $# -lt 2 || "$2" == --* ]]; then
        dbx_err "dbx_assemble_container: --exports requires a value"
        return 1
      fi
      exported_apps="${2:-}"
      shift 2
      ;;
    --unshare-*)
      unshare_flags+=("${1#--unshare-}=true")
      shift
      ;;
    --)
      shift
      break
      ;;
    --*)
      dbx_err "Unknown option: $1"
      return 1
      ;;
    *)
      dbx_err "Unexpected argument: $1"
      return 1
      ;;
    esac
  done

  if [[ -z "$name" ]]; then
    dbx_err "dbx_assemble_container: --name is required"
    return 1
  fi
  if [[ -z "$image" ]]; then
    dbx_err "dbx_assemble_container: --image is required"
    return 1
  fi

  local assemble_file
  assemble_file=$(mktemp)
  trap 'rm -f "${assemble_file:-}"' RETURN

  dbx_log "Creating container '${name}' with ${image}..."

  local root_flag="${root_flag:-}"
  [[ "$use_root" == "true" ]] && root_flag="root=true"

  local flags_str="${additional_flags[*]}"

  dbx_log "Generating assemble configuration..."

  {
    printf '%s\n' "[${name}]"
    printf '%s=%s\n' "image" "${image}"
    printf '%s=%s\n' "pull" "true"
    [[ -n "$init_pkg" ]] && printf '%s=%s\n' "init" "true"
    printf '%s=%s\n' "start_now" "true"
    [[ -n "$root_flag" ]] && printf '%s\n' "$root_flag"
    for unshare in "${unshare_flags[@]}"; do
      local unshare_key="unshare_${unshare%=*}"
      printf '%s=%s\n' "$unshare_key" "${unshare#*=}"
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
    [[ "$use_root" == "true" ]] && root_flag="--root "
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
    if ! distrobox-enter "$root_flag"--name "${name}" -- bash -x "${hook_script}"; then
      dbx_err "Post-hooks failed (continuing anyway)"
    fi
  fi
}

#------------------------------------------------------------------------------
# EXPORT MANAGEMENT
#------------------------------------------------------------------------------

# Export an application to the host
# Usage: dbx_do_export <container_name> <export_app> [rootful] [app_label]
dbx_do_export() {
  local container_name="$1"
  local export_app="$2"
  local use_root="${3:-false}"
  local app_label="${4:-$export_app}"

  dbx_log "Exporting ${app_label}..."

  local root_flag=""
  [[ "$use_root" == "true" ]] && root_flag="--root"

  if distrobox-enter $root_flag "${container_name}" -- distrobox-export -a "${export_app}" 2>&1; then
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

# Remove an export from the host
# Usage: dbx_do_uninstall <container_name> <export_app> [rootful]
dbx_do_uninstall() {
  local container_name="$1"
  local export_app="$2"
  local use_root="${3:-false}"

  dbx_log "Removing ${export_app} export..."

  if dbx_container_exists "$container_name" "$use_root"; then
    local root_flag=""
    [[ "$use_root" == "true" ]] && root_flag="--root"
    distrobox-enter $root_flag "${container_name}" -- distrobox-export -d -a "${export_app}" 2>/dev/null || true
  fi

  # Remove desktop files
  rm -f "$HOME/.local/share/applications/${container_name}-${export_app}.desktop" 2>/dev/null || true
  rm -f "$HOME/.local/share/applications/${container_name}-${export_app}.desktop.bak" 2>/dev/null || true

  dbx_log "Uninstall complete. Run with --install to reinstall."
}

# Remove export + container
# Usage: dbx_do_remove <container_name> <export_app> [rootful]
dbx_do_remove() {
  local container_name="$1"
  local export_app="$2"
  local use_root="${3:-false}"

  if ! dbx_confirm "This will remove the '${container_name}' container and all its data. This action cannot be undone."; then
    dbx_log "Removal cancelled."
    return 0
  fi

  dbx_log "Removing container and exports..."

  # Remove export if container exists
  if dbx_container_exists "$container_name" "$use_root"; then
    local root_flag=""
    [[ "$use_root" == "true" ]] && root_flag="--root"
    distrobox-enter $root_flag "${container_name}" -- distrobox-export -d -a "${export_app}" 2>/dev/null || true
  fi

  dbx_remove_container "$container_name"
  dbx_cleanup_desktop_files "$container_name"

  dbx_log "Removal complete."
}

#------------------------------------------------------------------------------
# DESKTOP FILE MANAGEMENT
#------------------------------------------------------------------------------

# Clean up old desktop files for a container
# Usage: dbx_cleanup_desktop_files <container_name>
dbx_cleanup_desktop_files() {
  local container_name="$1"
  dbx_log "Cleaning up old desktop files..."
  local apps_dir="$HOME/.local/share/applications"

  for f in "${apps_dir}/${container_name}"-*.desktop; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "${container_name}.desktop" ]] && continue
    rm -f "$f"
  done
  for f in "${apps_dir}/${container_name}"-*.desktop.bak; do
    [[ -f "$f" ]] || continue
    rm -f "$f"
  done
  update-desktop-database "${apps_dir}" 2>/dev/null || true
}

# Find all .desktop files that declare handling of http/https scheme handlers
# Usage: dbx_find_web_browser_desktop_files
dbx_find_web_browser_desktop_files() {
  local search_dirs=(
    "/var/lib/flatpak/exports/share/applications"
    "$HOME/.local/share/flatpak/exports/share/applications"
    "$HOME/.local/share/applications"
    "/usr/share/applications"
  )

  local results=()
  for dir in "${search_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' file; do
      if grep -q "MimeType=.*x-scheme-handler/http" "$file" 2>/dev/null; then
        results+=("$file")
      fi
    done < <(find "$dir" -name "*.desktop" -type f -print0 2>/dev/null)
  done

  printf '%s\n' "${results[@]}"
}

# Get container prefix for desktop files (container ID or name)
# Usage: dbx_get_container_prefix [container_name]
dbx_get_container_prefix() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  if dbx_is_inside_container; then
    source /var/run/.containerenv 2>/dev/null || true
    echo "${CONTAINER_ID:-}"
  else
    echo "$container_name"
  fi
}

# Clean up superfluous desktop files created by distrobox-export
# Usage: dbx_cleanup_exported_desktop_files <container_name> [app_name]
dbx_cleanup_exported_desktop_files() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  local app_name="${2:-}"
  local apps_dir="$HOME/.local/share/applications"
  local container_prefix
  container_prefix="$(dbx_get_container_prefix "$container_name")"

  if [[ -n "$container_prefix" && -n "$app_name" ]]; then
    rm -f "${apps_dir}/${container_prefix}-${app_name}.desktop" 2>/dev/null || true
    rm -f "${apps_dir}/${container_prefix}-${app_name}.desktop.bak" 2>/dev/null || true
    rm -f "${apps_dir}/${container_prefix}-${container_prefix}.desktop" 2>/dev/null || true
    rm -f "${apps_dir}/${container_prefix}-${container_prefix}.desktop.bak" 2>/dev/null || true
  fi

  update-desktop-database "${apps_dir}" 2>/dev/null || true
}

# Create XDG open bridge for container→host integration
# Usage: dbx_create_xdg_bridge [container_name]
dbx_create_xdg_bridge() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  local target="/usr/local/bin/xdg-open"

  if dbxe -- test -f "$target" && dbxe -- grep -q "org.freedesktop.portal.OpenURI" "$target" 2>/dev/null; then
    dbx_log "XDG open bridge already configured"
    return 0
  fi

  dbx_log "Creating XDG open bridge for container→host integration"
  dbxe -- sudo install -m 755 /dev/stdin "$target" <<'EOF'
#!/usr/bin/python3
import sys, dbus, os
os.environ["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path=/run/user/{os.getuid()}/bus"
try:
    bus = dbus.SessionBus()
    obj = bus.get_object("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop")
    dbus.Interface(obj, "org.freedesktop.portal.OpenURI").OpenURI("", sys.argv[1], {})
except Exception: pass
EOF
  dbxe -- sudo ln -sf "$target" /usr/local/bin/distrobox-host-exec 2>/dev/null || true
  dbx_log "Created XDG open bridge"
}

#------------------------------------------------------------------------------
# DEFAULT APPLICATION MANAGEMENT
#------------------------------------------------------------------------------

# Get the last saved default app (for restoration)
# Usage: dbx_get_last_default <category>
dbx_get_last_default() {
  local category="$1"
  local default_file="$HOME/.local/share/distrobox-defaults-${category}.txt"
  [[ -f "$default_file" ]] && cat "$default_file" || echo ""
}

# Save the current default app
# Usage: dbx_save_default <category> <default_value>
dbx_save_default() {
  local category="$1"
  local default_value="$2"
  local default_file="$HOME/.local/share/distrobox-defaults-${category}.txt"
  mkdir -p "$(dirname "$default_file")"
  echo "$default_value" >"$default_file"
}

# Set default application using xdg-settings
# Usage: dbx_set_default_app <category> <desktop_file>
# Categories: default-web-browser, default-mail-client, etc.
dbx_set_default_app() {
  local category="$1"
  local desktop_file="$2"
  local desktop_filename
  desktop_filename="$(basename "$desktop_file")"

  local current_default
  current_default="$(xdg-settings get "$category" 2>/dev/null || echo "")"

  if [[ -n "$current_default" && "$current_default" != "$desktop_filename" ]]; then
    dbx_save_default "$category" "$current_default"
    dbx_log "Stored previous default: $current_default"
  fi

  if [[ "$current_default" == "$desktop_filename" ]]; then
    dbx_log "Default $category already set to: $desktop_filename"
    return 0
  fi

  if ! grep -q "MimeType=.*x-scheme-handler" "$desktop_file" 2>/dev/null && [[ "$category" == *"web-browser"* ]]; then
    dbx_err "Desktop file does not declare MIME handlers: $desktop_file"
    return 1
  fi

  dbx_log "Setting default $category to: $desktop_filename"
  if xdg-settings set "$category" "$desktop_filename" 2>/dev/null; then
    dbx_log "Default $category set successfully"
    return 0
  else
    dbx_err "Failed to set default $category"
    return 1
  fi
}

# Restore previous default application
# Usage: dbx_restore_default <category>
dbx_restore_default() {
  local category="$1"
  local previous_default
  previous_default="$(dbx_get_last_default "$category")"

  if [[ -z "$previous_default" ]]; then
    dbx_log "No previous default stored for $category"
    return 0
  fi

  local desktop_found="false"
  if [[ "$category" == *"web-browser"* ]]; then
    while IFS= read -r file; do
      if [[ "$(basename "$file")" == "$previous_default" ]]; then
        desktop_found="true"
        break
      fi
    done < <(dbx_find_web_browser_desktop_files)
  fi

  if [[ "$desktop_found" == "false" && "$category" == *"web-browser"* ]]; then
    dbx_log "Previously stored default no longer available: $previous_default"
    rm -f "$HOME/.local/share/distrobox-defaults-${category}.txt"
    return 0
  fi

  local current_default
  current_default="$(xdg-settings get "$category" 2>/dev/null || echo "")"

  if [[ "$current_default" == "$previous_default" ]]; then
    rm -f "$HOME/.local/share/distrobox-defaults-${category}.txt"
    return 0
  fi

  dbx_log "Restoring default $category to: $previous_default"
  if xdg-settings set "$category" "$previous_default" 2>/dev/null; then
    rm -f "$HOME/.local/share/distrobox-defaults-${category}.txt"
    dbx_log "Default $category restored successfully"
    return 0
  else
    dbx_err "Failed to restore default $category"
    return 1
  fi
}

#------------------------------------------------------------------------------
# WRAPPER DETECTION
#------------------------------------------------------------------------------

dbx_detect_wrapper() {
  local wrapper_name="$1"

  local wrapper_path
  wrapper_path="$(command -v "$wrapper_name" 2>/dev/null || echo "")"
  if [[ -n "$wrapper_path" && -x "$wrapper_path" ]]; then
    dbx_err "Using ${wrapper_name}: $wrapper_path"
    echo "$wrapper_path"
    return 0
  fi

  local flags_script
  flags_script="$(command -v chromium-flags.sh 2>/dev/null || echo "")"
  if [[ -n "$flags_script" && -x "$flags_script" ]]; then
    dbx_err "Using chromium-flags.sh: $flags_script"
    echo "$flags_script"
    return 0
  fi

  dbx_err "No wrapper script found, using native binary"
  echo ""
  return 1
}

dbx_build_exec_target() {
  local wrapper_path="$1"
  local pkg_name="$2"
  local use_flatpak="$3"
  local container_name="${4:-${CONTAINER_NAME:-}}"
  local flatpak_id="${5:-}"

  if [[ -n "$wrapper_path" && -x "$wrapper_path" ]]; then
    echo "$wrapper_path"
    return 0
  fi

  if command -v chromium-flags.sh &>/dev/null && [[ -x "$(command -v chromium-flags.sh)" ]]; then
    if [[ "$use_flatpak" == "true" && -n "$flatpak_id" ]]; then
      echo "$(command -v chromium-flags.sh) flatpak run ${flatpak_id}"
      return 0
    else
      echo "$(command -v chromium-flags.sh) distrobox-enter -n ${container_name} -- /usr/bin/${pkg_name}"
      return 0
    fi
  fi

  if [[ "$use_flatpak" == "true" && -n "$flatpak_id" ]]; then
    echo "flatpak run ${flatpak_id}"
  else
    echo "$pkg_name"
  fi
}

dbx_install_dnf() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  local pkg_name="$2"
  local repo_url="$3"

  if dbxe -- rpm -q "$pkg_name" &>/dev/null; then
    dbx_log "${pkg_name} already installed in container"
  else
    dbx_log "Installing ${pkg_name} via DNF (inside container)"
    dbxe -- sudo dnf install -y dnf-plugins-core
    dbxe -- sudo dnf config-manager addrepo --overwrite --from-repofile="${repo_url}"
    dbxe -- sudo dnf install -y "${pkg_name}"
  fi
}

dbx_configure_desktop_file() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  local pkg_name="$2"
  local use_flatpak="$3"
  local flatpak_id="$4"
  local wrapper_path="$5"
  local icon_name="${6:-}"

  local apps_dir="$HOME/.local/share/applications"
  local desktop_file=""
  local exec_target=""

  exec_target=$(dbx_build_exec_target "$wrapper_path" "$pkg_name" "$use_flatpak" "$container_name" "$flatpak_id")

  local launcher_desc
  if [[ -n "$wrapper_path" && -x "$wrapper_path" ]]; then
    launcher_desc="$(basename "$wrapper_path")"
  elif command -v chromium-flags.sh &>/dev/null && [[ -x "$(command -v chromium-flags.sh)" ]]; then
    launcher_desc="chromium-flags.sh"
  else
    launcher_desc="native browser"
  fi

  if [[ "$use_flatpak" == "true" ]]; then
    local src="$HOME/.local/share/flatpak/exports/share/applications/${flatpak_id}.desktop"
    desktop_file="$apps_dir/${flatpak_id}.desktop"

    if [[ ! -f "$src" ]]; then
      dbx_err "Flatpak desktop file not found: $src"
      return 1
    fi

    if [[ ! -f "$desktop_file" ]] || ! diff -q "$src" "$desktop_file" &>/dev/null; then
      install -Z -m 644 "$src" "$desktop_file"
      dbx_log "Installed Flatpak desktop file"
    fi
  else
    local container_prefix
    container_prefix="$(dbx_get_container_prefix "$container_name")"
    if [[ -n "$container_prefix" ]]; then
      desktop_file="$apps_dir/${container_prefix}-${pkg_name}.desktop"
    else
      desktop_file=$(find "$apps_dir" -maxdepth 1 -name "*${pkg_name}*.desktop" -type f 2>/dev/null | head -n1)
    fi
  fi

  if [[ ! -f "$desktop_file" ]]; then
    dbx_err "Desktop file not found: $desktop_file"
    return 1
  fi

  local current_exec
  current_exec=$(grep "^Exec=" "$desktop_file" | head -n1 | cut -d= -f2-)

  if [[ "$current_exec" == "$exec_target"* ]] && grep -q "^StartupWMClass=" "$desktop_file"; then
    dbx_log "Desktop file already configured for $launcher_desc"
    return 0
  fi

  cp "$desktop_file" "$desktop_file.bak"

  awk -v target="$exec_target" '
    /^Exec=/ {
      line = substr($0, 6)
      trailing = ""
      if (match(line, /(%U|%u|%F|%f|--incognito|--new-window|--temp-profile)/)) {
        trailing = substr(line, RSTART)
      }
      print "Exec=" target " " trailing
      next
    }
    { print }
  ' "$desktop_file" >"$desktop_file.tmp" && mv "$desktop_file.tmp" "$desktop_file"

  if [[ "$use_flatpak" == "true" ]]; then
    sed -i '/@@/d' "$desktop_file"
  fi

  local wm_class="$flatpak_id"
  [[ "$use_flatpak" == "false" ]] && wm_class="$pkg_name"

  grep -v "^StartupWMClass=" "$desktop_file" >"$desktop_file.tmp" && mv "$desktop_file.tmp" "$desktop_file"

  awk -v wc="StartupWMClass=${wm_class}" '
    BEGIN { in_desktop_entry = 0; added = 0 }
    /^\[Desktop Entry\]/ { in_desktop_entry = 1 }
    /^\[/ && !/^\[Desktop Entry\]/ { in_desktop_entry = 0 }
    /^Exec=/ && in_desktop_entry && !added { print; print wc; added = 1; next }
    { print }
  ' "$desktop_file" >"$desktop_file.tmp" && mv "$desktop_file.tmp" "$desktop_file"

  if [[ -n "$icon_name" ]]; then
    sed -i "s|^Icon=.*|Icon=${icon_name}|" "$desktop_file"
  fi

  update-desktop-database "$apps_dir" 2>/dev/null || true
  dbx_log "Configured desktop file for $launcher_desc"

  dbx_set_default_app "default-web-browser" "$desktop_file"
}

dbx_cleanup_app_desktop_files() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  local app_id="$2"
  local apps_dir="$HOME/.local/share/applications"
  local container_prefix
  container_prefix="$(dbx_get_container_prefix "$container_name")"

  if [[ -n "$container_prefix" ]]; then
    rm -f "${apps_dir}/${container_prefix}-${app_id}.desktop" 2>/dev/null || true
    rm -f "${apps_dir}/${container_prefix}-${app_id}.desktop.bak" 2>/dev/null || true
  fi

  rm -f "${apps_dir}/${app_id}.desktop" 2>/dev/null || true
  rm -f "${apps_dir}/${app_id}.desktop.bak" 2>/dev/null || true

  update-desktop-database "${apps_dir}" 2>/dev/null || true
}

#------------------------------------------------------------------------------
# ARGUMENT PARSING
#------------------------------------------------------------------------------

# Parse CLI arguments and set ACTION variable
# Usage: dbx_parse_args "$@"
# Sets: ACTION (default|install|uninstall|recreate), INSTALL_TYPE, RM_CONTAINER, RECREATE
# Returns: 0 if --help was requested, 1 on error, 2 on normal completion
dbx_parse_args() {
  ACTION="${ACTION:-default}"
  INSTALL_TYPE="${INSTALL_TYPE:-}"
  RM_CONTAINER="${RM_CONTAINER:-false}"
  RECREATE="${RECREATE:-false}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --recreate)
      ACTION="recreate"
      RECREATE="true"
      shift
      ;;
    --install | --uninstall)
      if [[ "$1" == "--install" ]]; then
        ACTION="install"
      else
        ACTION="uninstall"
      fi
      shift
      # Consume value if present and not another flag
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

# Show help and exit
# Usage: dbx_show_help <script_name> <help_text>
dbx_show_help() {
  local script_name="$1"
  local help_text="$2"
  printf "Usage: %s [OPTIONS]\n\n%s\n" "${script_name##*/}" "$help_text"
  exit 0
}

# Prompt for confirmation (returns 0 if yes, 1 if no)
# Usage: dbx_confirm <message>
dbx_confirm() {
  local message="$1"
  local response=""
  dbx_err "$message"
  read -rp "Proceed? [y/N] " response
  case "$response" in
  [yY] | [yY][eE][sS]) return 0 ;;
  *) return 1 ;;
  esac
}
