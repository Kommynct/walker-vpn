# Both the desktop client and the privileged backend use this allowlist.
app_session_keys=(
    DISPLAY WAYLAND_DISPLAY XAUTHORITY LANG LC_ALL TZ
    XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP
    XDG_DATA_HOME XDG_DATA_DIRS XDG_CONFIG_HOME XDG_CONFIG_DIRS XDG_CACHE_HOME XDG_STATE_HOME
    QT_QPA_PLATFORM QT_QPA_PLATFORMTHEME QT_PLUGIN_PATH QT_STYLE_OVERRIDE
    QT_QPA_PLATFORM_PLUGIN_PATH QT_WAYLAND_RECONNECT QT_QUICK_CONTROLS_STYLE
    GTK_THEME GTK_PATH GDK_BACKEND GSETTINGS_SCHEMA_DIR XCURSOR_THEME XCURSOR_SIZE
    PIPEWIRE_REMOTE PULSE_SERVER PATH
)

desktop_zoneinfo_dir() {
    local localtime=$1 target directory
    # Flatpak compares the immediate localtime symlink with TZDIR. Keep the
    # configured path even when the directory itself is a symlink.
    if target=$(readlink -- "$localtime"); then
        if [[ $target != /* ]]; then target=${localtime%/*}/$target; fi
        case $target in
            *//*|*/./*|*/../*) target=$(realpath --canonicalize-missing --no-symlinks -- "$target") || return 1 ;;
        esac
        if [[ $target == */zoneinfo/* && -r $target ]]; then
            printf '%s/zoneinfo\n' "${target%/zoneinfo/*}"
            return 0
        fi
    fi
    for directory in "${TZDIR:-}" /etc/zoneinfo /usr/share/zoneinfo; do
        if [[ $directory == /* && -d $directory ]]; then
            printf '%s\n' "$directory"
            return 0
        fi
    done
    return 1
}
