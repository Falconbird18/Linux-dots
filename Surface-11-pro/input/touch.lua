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
-- Also works in clients without Wayland text-input support.
hl.bind("SUPER + CTRL + K", hl.dsp.exec_cmd("busctl --user call sm.puri.OSK0 /sm/puri/OSK0 sm.puri.OSK0 SetVisible b true"), { description = "Show touch keyboard" })
hl.on("hyprland.start", function()
    hl.exec_cmd("sh -c 'systemctl --user import-environment HYPRLAND_INSTANCE_SIGNATURE WAYLAND_DISPLAY XDG_RUNTIME_DIR && systemctl --user restart surface11-touch.service'")
end)
