-- Surface touch configuration. Auto-rotation owns the input transforms.
hl.config({
    input = {
        touchdevice = { enabled = true, output = "eDP-1" },
        tablet = { output = "eDP-1", relative_input = false },
    },
    -- Keep native taps; edge gestures intercept touch streams on this build.
    gestures = { workspace_swipe_touch = false },
    cursor = { hide_on_touch = false },
})
-- Remove the old forced-show shortcut; text-input focus owns keyboard visibility.
hl.unbind("SUPER + CTRL + K")
local observer = os.getenv("HOME") .. "/.local/lib/surface11/touch-observer.so"
local file = io.open(observer, "r")
if file then
    file:close()
    hl.plugin.load(observer)
end
hl.on("hyprland.start", function()
    hl.exec_cmd("sh -c 'systemctl --user import-environment HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY XDG_RUNTIME_DIR && systemctl --user restart surface11-touch.service'")
end)

hl.on("config.reloaded", function()
    hl.exec_cmd("systemctl --user restart surface11-touch.service")
end)
