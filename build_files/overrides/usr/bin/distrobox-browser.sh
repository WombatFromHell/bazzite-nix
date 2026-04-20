#!/usr/bin/env bash
#==============================================================================
# distrobox-browser.sh - Browser-specific helpers for distrobox-based installers
#
# Provides utilities for web browser integration: default app handling,
# wrapper detection, desktop file configuration, and XDG bridge setup.
#
# Usage: source this file AFTER distrobox-installer.sh
#
# CONFIGURATION (optional, enables browser mode automatically):
#   readonly DBX_PKG_NAME="..."        # Package name in container
#   readonly DBX_REPO_URL="..."        # DNF repo URL (if installing via DNF)
#   readonly DBX_FLATPAK_ID="..."     # Flatpak ID (if using Flatpak)
#   readonly DBX_WRAPPER="..."     # Wrapper script name (e.g., brave-wrapper.sh)
#   readonly DBX_ICON_NAME="..."    # Icon name
#   readonly DBX_FLATPAK_ONLY="true"  # Only allow Flatpak install
#
# Auto-detected: if any of DBX_PKG_NAME, DBX_REPO_URL, DBX_FLATPAK_ID are set,
# browser mode is enabled and these functions run automatically:
#   - dbx_browser_create_xdg_bridge  (via DBX_POST_CREATE_HOOK)
#   - dbx_browser_configure_desktop  (via DBX_POST_EXPORT_HOOK)
#   - dbx_browser_set_default     (automatic after export)
#==============================================================================

#------------------------------------------------------------------------------
# CONFIGURATION
#------------------------------------------------------------------------------

DBX_PKG_NAME="${DBX_PKG_NAME:-}"
DBX_REPO_URL="${DBX_REPO_URL:-}"
DBX_FLATPAK_ID="${DBX_FLATPAK_ID:-}"
DBX_WRAPPER="${DBX_WRAPPER:-}"
DBX_ICON_NAME="${DBX_ICON_NAME:-}"
DBX_FLATPAK_ONLY="${DBX_FLATPAK_ONLY:-false}"
DBX_FLATPAK="${DBX_FLATPAK:-false}"

# Parse --flatpak from CLI args if present (must be called by browser installer scripts)
dbx_parse_flatpak_flag() {
  for arg in "$@"; do
    [[ "$arg" == "--flatpak" ]] && DBX_FLATPAK="true" && break
  done
}

# Detect browser mode
_dbx_is_browser_mode() {
  [[ -n "$DBX_PKG_NAME" || -n "$DBX_REPO_URL" || -n "$DBX_FLATPAK_ID" ]]
}

#------------------------------------------------------------------------------
# BROWSER DESKTOP FILE MANAGEMENT
#------------------------------------------------------------------------------

dbx_browser_find_desktop_files() {
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

dbx_browser_get_last_default() {
  local category="$1"
  local default_file="$HOME/.local/share/distrobox-defaults-${category}.txt"
  [[ -f "$default_file" ]] && cat "$default_file" || echo ""
}

dbx_browser_save_default() {
  local category="$1"
  local default_value="$2"
  local default_file="$HOME/.local/share/distrobox-defaults-${category}.txt"
  mkdir -p "$(dirname "$default_file")"
  echo "$default_value" >"$default_file"
}

dbx_browser_set_default() {
  local category="$1"
  local desktop_file="$2"
  local desktop_filename
  desktop_filename="$(basename "$desktop_file")"

  local current_default
  current_default="$(xdg-settings get "$category" 2>/dev/null || echo "")"

  if [[ -n "$current_default" && "$current_default" != "$desktop_filename" ]]; then
    dbx_browser_save_default "$category" "$current_default"
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
  xdg-settings set "$category" "$desktop_filename" 2>/dev/null && dbx_log "Default $category set successfully"
}

dbx_browser_restore_default() {
  local category="$1"
  local previous_default
  previous_default="$(dbx_browser_get_last_default "$category")"

  [[ -z "$previous_default" ]] && dbx_log "No previous default stored for $category" && return 0

  local desktop_found="false"
  if [[ "$category" == *"web-browser"* ]]; then
    while IFS= read -r file; do
      [[ "$(basename "$file")" == "$previous_default" ]] && desktop_found="true" && break
    done < <(dbx_browser_find_desktop_files)
  fi

  if [[ "$desktop_found" == "false" && "$category" == *"web-browser"* ]]; then
    dbx_log "Previously stored default no longer available: $previous_default"
    rm -f "$HOME/.local/share/distrobox-defaults-${category}.txt"
    return 0
  fi

  local current_default
  current_default="$(xdg-settings get "$category" 2>/dev/null || echo "")"

  [[ "$current_default" == "$previous_default" ]] && rm -f "$HOME/.local/share/distrobox-defaults-${category}.txt" && return 0

  dbx_log "Restoring default $category to: $previous_default"
  xdg-settings set "$category" "$previous_default" 2>/dev/null && rm -f "$HOME/.local/share/distrobox-defaults-${category}.txt"
}

#------------------------------------------------------------------------------
# WRAPPER DETECTION
#------------------------------------------------------------------------------

dbx_browser_detect_wrapper() {
  local wrapper_name="${1:-${DBX_WRAPPER:-}}"

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

dbx_browser_build_exec_target() {
  local wrapper_path="$1"
  local pkg_name="${2:-${DBX_PKG_NAME:-}}"
  local use_flatpak="${3:-false}"
  local container_name="${4:-${CONTAINER_NAME:-}}"
  local flatpak_id="${5:-${DBX_FLATPAK_ID:-}}"

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

#------------------------------------------------------------------------------
# DNF INSTALLATION
#------------------------------------------------------------------------------

dbx_browser_install_dnf() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  local pkg_name="${2:-${DBX_PKG_NAME:-}}"
  local repo_url="${3:-${DBX_REPO_URL:-}}"

  [[ -z "$pkg_name" ]] && dbx_err "dbx_browser_install_dnf: DBX_PKG_NAME not set" && return 1

  if dbxe -- rpm -q "$pkg_name" &>/dev/null; then
    dbx_log "${pkg_name} already installed in container"
  else
    dbx_log "Installing ${pkg_name} via DNF (inside container)"
    dbxe -- sudo dnf install -y dnf-plugins-core
    [[ -n "$repo_url" ]] && dbxe -- sudo dnf config-manager addrepo --overwrite --from-repofile="${repo_url}"
    dbxe -- sudo dnf install -y "${pkg_name}"
  fi
}

#------------------------------------------------------------------------------
# DESKTOP FILE CONFIGURATION
#------------------------------------------------------------------------------

dbx_browser_cleanup_desktop() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  local app_id="${2:-${DBX_FLATPAK_ID:-${DBX_PKG_NAME:-}}}"
  local apps_dir="$HOME/.local/share/applications"
  local container_prefix
  container_prefix="$(dbx_get_container_prefix "$container_name")"

  [[ -n "$container_prefix" ]] && rm -f "${apps_dir}/${container_prefix}-${app_id}.desktop" "${apps_dir}/${container_prefix}-${app_id}.desktop.bak" 2>/dev/null || true
  rm -f "${apps_dir}/${app_id}.desktop" "${apps_dir}/${app_id}.desktop.bak" 2>/dev/null || true

  update-desktop-database "${apps_dir}" 2>/dev/null || true
}

dbx_browser_cleanup_exported() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  local app_name="${2:-${DBX_FLATPAK_ID:-${DBX_PKG_NAME:-}}}"
  local apps_dir="$HOME/.local/share/applications"
  local container_prefix
  container_prefix="$(dbx_get_container_prefix "$container_name")"

  if [[ -n "$container_prefix" && -n "$app_name" ]]; then
    rm -f "${apps_dir}/${container_prefix}-${app_name}.desktop" "${apps_dir}/${container_prefix}-${app_name}.desktop.bak" 2>/dev/null || true
    rm -f "${apps_dir}/${container_prefix}-${container_prefix}.desktop" "${apps_dir}/${container_prefix}-${container_prefix}.desktop.bak" 2>/dev/null || true
  fi

  update-desktop-database "${apps_dir}" 2>/dev/null || true
}

dbx_browser_configure_desktop() {
  local container_name="${1:-${CONTAINER_NAME:-}}"
  local pkg_name="${2:-${DBX_PKG_NAME:-}}"
  local use_flatpak="${3:-false}"
  local flatpak_id="${4:-${DBX_FLATPAK_ID:-}}"
  local wrapper_path="${5:-}"
  local icon_name="${6:-${DBX_ICON_NAME:-}}"

  local apps_dir="$HOME/.local/share/applications"
  local desktop_file=""
  local exec_target=""

  exec_target=$(dbx_browser_build_exec_target "$wrapper_path" "$pkg_name" "$use_flatpak" "$container_name" "$flatpak_id")

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

    [[ ! -f "$src" ]] && dbx_err "Flatpak desktop file not found: $src" && return 1

    [[ ! -f "$desktop_file" ]] || ! diff -q "$src" "$desktop_file" &>/dev/null && install -Z -m 644 "$src" "$desktop_file" && dbx_log "Installed Flatpak desktop file"
  else
    local container_prefix
    container_prefix="$(dbx_get_container_prefix "$container_name")"
    if [[ -n "$container_prefix" ]]; then
      desktop_file="$apps_dir/${container_prefix}-${pkg_name}.desktop"
    else
      desktop_file=$(find "$apps_dir" -maxdepth 1 -name "*${pkg_name}*.desktop" -type f 2>/dev/null | head -n1)
    fi
  fi

  [[ ! -f "$desktop_file" ]] && dbx_err "Desktop file not found: $desktop_file" && return 1

  local current_exec
  current_exec=$(grep "^Exec=" "$desktop_file" | head -n1 | cut -d= -f2-)

  if [[ "$current_exec" == "$exec_target"* ]] && grep -q "^StartupWMClass=" "$desktop_file"; then
    dbx_log "Desktop file already configured for $launcher_desc"
    return 0
  fi

  cp "$desktop_file" "$desktop_file.bak"

  if [[ "$use_flatpak" == "true" ]]; then
    awk -v target="$exec_target" '
    /^@@/ { next }
    /^Exec=/ { next }
    /^\[Desktop Entry\]/ { 
      in_desktop = 1
      print
      next
    }
    in_desktop == 1 && /^\[A-Z]/ && !/^Exec=/ { 
      print "Exec=" target " %U"
      in_desktop = 0
    }
    /^\[Desktop Action/ {
      in_action = 1
      action = $0
      gsub(/.*\[Desktop Action /, "", action)
      gsub(/\].*/, "", action)
      print
      next
    }
    in_action == 1 && /^Exec=/ { next }
    in_action == 1 && /^[A-Z]/ { 
      if (action == "new-window") {
        print "Exec=" target
      } else if (action == "new-private-window") {
        print "Exec=" target " --incognito"
      } else if (action == "new-tor-window") {
        print "Exec=" target " --tor"
      }
      in_action = 0
    }
    { print }
    ' "$desktop_file.bak" >"$desktop_file"
  else
    awk -v target="$exec_target" '
    /^Exec=/ {
      line = substr($0, 6)
      trailing = ""
      if (match(line, /(%[UUF]|[ ]--[a-z-]+)/)) {
        trailing = substr(line, RSTART)
      }
      print "Exec=" target (trailing ? " " trailing : "")
      next
    }
    { print }
    ' "$desktop_file" >"$desktop_file.tmp" && mv "$desktop_file.tmp" "$desktop_file"
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

  [[ -n "$icon_name" ]] && sed -i "s|^Icon=.*|Icon=${icon_name}|" "$desktop_file"

  update-desktop-database "$apps_dir" 2>/dev/null || true
  dbx_log "Configured desktop file for $launcher_desc"

  dbx_browser_set_default "default-web-browser" "$desktop_file"
}

#------------------------------------------------------------------------------
# XDG BRIDGE
#------------------------------------------------------------------------------

dbx_browser_create_xdg_bridge() {
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
# FLATPAK HELPERS
#------------------------------------------------------------------------------

dbx_browser_install_flatpak() {
  local flatpak_id="${1:-${DBX_FLATPAK_ID:-}}"

  [[ -z "$flatpak_id" ]] && dbx_err "dbx_browser_install_flatpak: DBX_FLATPAK_ID not set" && return 1

  if flatpak list --app --columns=application 2>/dev/null | grep -q "^${flatpak_id}$"; then
    dbx_log "Flatpak already installed: ${flatpak_id}"
  else
    dbx_log "Installing via Flatpak: ${flatpak_id}"
    flatpak install --user -y "${flatpak_id}"
  fi
}

#------------------------------------------------------------------------------
# BROWSER AUTO-HOOKS (integrate with dbx_main)
#------------------------------------------------------------------------------

_dbx_browser_pre_export_hook() {
  [[ "$1" != "export" ]] && return 0

  local use_flatpak="false"
  [[ -n "$DBX_FLATPAK_ID" && "$DBX_FLATPAK_ONLY" != "true" ]] || use_flatpak="true"

  if [[ "$use_flatpak" == "true" || -z "$DBX_REPO_URL" ]]; then
    dbx_browser_install_flatpak
  else
    dbx_browser_install_dnf
  fi

  dbx_browser_create_xdg_bridge
}

_dbx_browser_post_export_hook() {
  local use_flatpak="false"
  [[ -n "$DBX_FLATPAK_ID" && "$DBX_FLATPAK_ONLY" != "true" ]] || use_flatpak="true"

  if [[ "$use_flatpak" == "true" || -z "$DBX_REPO_URL" ]]; then
    dbx_browser_configure_desktop "" "" "true"
  else
    dbx_browser_cleanup_exported
    dbx_browser_configure_desktop
  fi
}

#------------------------------------------------------------------------------
# BROWSER INSTALLATION METHOD DETECTION
#------------------------------------------------------------------------------

dbx_browser_detect_installed() {
  local flatpak_id="${1:-${DBX_FLATPAK_ID:-}}"
  local container_name="${2:-${CONTAINER_NAME:-}}"

  if [[ -n "$flatpak_id" ]] && flatpak list --app --columns=application 2>/dev/null | grep -q "^${flatpak_id}$"; then
    echo "flatpak"
    return 0
  fi

  if [[ -n "$container_name" ]] && dbx_container_exists "$container_name" 2>/dev/null; then
    echo "dnf"
    return 0
  fi

  echo "none"
}

dbx_browser_uninstall_flatpak() {
  local flatpak_id="${1:-${DBX_FLATPAK_ID:-}}"
  local apps_dir="$HOME/.local/share/applications"

  [[ -z "$flatpak_id" ]] && dbx_err "dbx_browser_uninstall_flatpak: DBX_FLATPAK_ID not set" && return 1

  local was_installed="false"
  if flatpak list --app --columns=application 2>/dev/null | grep -q "^${flatpak_id}$"; then
    dbx_log "Uninstalling Flatpak: ${flatpak_id}"
    flatpak remove --user -y "${flatpak_id}" 2>/dev/null || flatpak remove -y "${flatpak_id}" 2>/dev/null || true
    was_installed="true"
  else
    dbx_log "Flatpak not installed, skipping uninstall."
  fi

  if [[ -f "${apps_dir}/${flatpak_id}.desktop" ]]; then
    rm -f "${apps_dir}/${flatpak_id}.desktop" "${apps_dir}/${flatpak_id}.desktop.bak"
    update-desktop-database "$apps_dir" 2>/dev/null || true
    dbx_log "Removed desktop file: ${apps_dir}/${flatpak_id}.desktop"
  elif [[ "$was_installed" == "true" ]]; then
    dbx_log "Desktop file already removed."
  fi
}

dbx_browser_flatpak_desktop_file() {
  local wrapper_path="${1:-}"
  local flatpak_id="${DBX_FLATPAK_ID:-}"
  local apps_dir="$HOME/.local/share/applications"

  [[ -z "$wrapper_path" || ! -x "$wrapper_path" ]] && dbx_err "Wrapper not found: $wrapper_path" && return 1
  [[ -z "$flatpak_id" ]] && dbx_err "DBX_FLATPAK_ID not set" && return 1

  local flatpak_apps_dir="$HOME/.local/share/flatpak/exports/share/applications"
  [[ -d "$flatpak_apps_dir" ]] || flatpak_apps_dir="/var/lib/flatpak/exports/share/applications"
  local src_desktop_file="${flatpak_apps_dir}/${flatpak_id}.desktop"

  [[ ! -f "$src_desktop_file" ]] && dbx_err "Flatpak desktop not found: $src_desktop_file" && return 1

  local desktop_file="${apps_dir}/${flatpak_id}.desktop"
  mkdir -p "$apps_dir"

  cp "$src_desktop_file" "$desktop_file"
  cp "$src_desktop_file" "${desktop_file}.bak"

  local wm_class="${DBX_PKG_NAME:-}"
  if [[ -z "$wm_class" ]]; then
    wm_class=$(basename "$wrapper_path" .sh)
    [[ "$wm_class" == "$wrapper_path" ]] && wm_class="$flatpak_id"
  fi
  sed -i "s|^StartupWMClass=.*|StartupWMClass=${wm_class}|" "$desktop_file"

  local action=""
  local tmp_file="${desktop_file}.tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "[Desktop Entry]" ]]; then
      action=""
      echo "$line"
    elif [[ "$line" == "[Desktop Action new-window]" ]]; then
      action="new-window"
      echo "$line"
    elif [[ "$line" == "[Desktop Action new-private-window]" ]]; then
      action="new-private-window"
      echo "$line"
    elif [[ "$line" == "[Desktop Action new-tor-window]" ]]; then
      action="new-tor-window"
      echo "$line"
    elif [[ "$line" == Exec=* ]]; then
      if [[ -z "$action" ]]; then
        echo "Exec=${wrapper_path} %U"
      elif [[ "$action" == "new-window" ]]; then
        echo "Exec=${wrapper_path}"
      elif [[ "$action" == "new-private-window" ]]; then
        echo "Exec=${wrapper_path} --incognito"
      elif [[ "$action" == "new-tor-window" ]]; then
        echo "Exec=${wrapper_path} --tor"
      fi
      continue
    else
      echo "$line"
    fi
  done <"$desktop_file" >"$tmp_file"
  mv "$tmp_file" "$desktop_file"

  update-desktop-database "$apps_dir" 2>/dev/null || true
  dbx_log "Configured Flatpak desktop file: $desktop_file"
}

dbx_browser_flatpak_is_configured() {
  local wrapper_path="${1:-}"
  local flatpak_id="${DBX_FLATPAK_ID:-}"
  local desktop_file="$HOME/.local/share/applications/${flatpak_id}.desktop"

  [[ -f "$desktop_file" ]] || return 1

  if [[ -z "$wrapper_path" ]]; then
    return 0
  fi

  local wrapper_name
  wrapper_name=$(basename "$wrapper_path")
  grep -q "Exec=.*${wrapper_name}" "$desktop_file" 2>/dev/null
}

# Auto-register hooks if browser mode detected
# These can be overridden by setting DBX_PRE/POST_CREATE/EXPORT_HOOK
if _dbx_is_browser_mode; then
  DBX_PRE_EXPORT_HOOK="${DBX_PRE_EXPORT_HOOK:-_dbx_browser_pre_export_hook}"
  DBX_POST_EXPORT_HOOK="${DBX_POST_EXPORT_HOOK:-_dbx_browser_post_export_hook}"
  DBX_POST_CREATE_HOOK="${DBX_POST_CREATE_HOOK:-dbx_browser_create_xdg_bridge}"
fi
