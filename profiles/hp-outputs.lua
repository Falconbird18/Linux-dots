-- HP Pavilion Laptop 15-eh3xxx, captured from hyprctl monitors on 2026-10-24.
-- Internal AU Optronics panel: 1920x1080 at 60.164 Hz, 100%, SDR, VRR off.
-- The fallback allows external monitors to connect using their preferred mode.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
hl.monitor({ output = "eDP-1", mode = "1920x1080@60.164", position = "0x0", scale = 1, transform = 0, vrr = 0, bitdepth = 10, cm = "srgb" })
