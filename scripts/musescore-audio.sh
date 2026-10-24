# Register and verify every bundled Dragonfly VST3 effect with the active package.
register_reverbs() {
    local plugin registry registration_backup
    if $DRY_RUN; then
        echo 'Would register and verify all Dragonfly VST3 reverbs with /usr/bin/mscore.'
        return
    fi
    registry=$DATA_HOME/MuseScore/MuseScore4/known_audio_plugins.json
    mkdir -p -- "$(dirname -- "$registry")"
    if [[ -f $registry ]]; then
        registration_backup=$(mktemp "${registry}.backup-XXXXXX")
        cp -p -- "$registry" "$registration_backup"
        printf 'Plugin registry backup: %s\n' "$registration_backup"
    fi
    local -a plugins=(/usr/lib/vst3/Dragonfly*.vst3)
    ((${#plugins[@]})) || { echo 'Dragonfly VST3 bundles are missing.' >&2; return 1; }
    for plugin in "${plugins[@]}"; do
        QT_QPA_PLATFORM=offscreen MU_QT_QPA_PLATFORM=offscreen timeout 30s \
            /usr/bin/mscore --register-audio-plugin "$plugin"
    done
    python3 - "$registry" "${plugins[@]}" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    plugins = json.load(f)
for path in sys.argv[2:]:
    if not any(p.get('path') == path and p.get('enabled') for p in plugins):
        sys.exit(f'Plugin registration failed: {path}. A VST3-enabled MuseScore build is required.')
print('Verified: all installed Dragonfly reverbs are enabled in MuseScore.')
PY
}
