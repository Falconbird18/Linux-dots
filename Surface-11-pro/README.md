# Intel Surface Pro 11 Linux setup

One entry point installs the fixes maintained in this folder:

```bash
bash install-surface11.sh
```

Run from the downloaded/cloned `Surface-11-pro` folder as your desktop user.
Keep that entire folder, including `patches/` and `wireplumber/` and helper scripts. The master
installer calls those helpers; there is no need to run them individually.
It requests sudo for privileged steps and never reboots automatically.

If the patched kernel is not running, the installer builds and installs it first.
Reboot, select **Linux Surface11 Custom**, and run the **same command again**.
It then installs/repairs the standard camera devices and tests actual frames.
On the already patched kernel, it skips the build and goes directly to cameras.

## Supported configuration

| Item | Current scope |
| --- | --- |
| Hardware | Intel Surface Pro 11 for Business, SKU `Surface_Pro_11th_Edition_With_Intel_For_Business_2103` |
| Architecture | x86-64; Snapdragon/ARM models are rejected |
| Distribution | Arch-based, using pacman and systemd |
| Kernel installation | systemd-boot, with the ESP mounted at `/efi` |
| Driver fixes | Existing SoundWire RT1320 quirk, camera power/bridge/rotation fixes, IMX681 sensor integration |
| Webcam compatibility | One public front/rear pair shared by V4L2 and PipeWire apps; native sources are private relay inputs |

This is an experimental installer for this specific configuration, not a general
Surface installer or a claim that every device feature works. Camera quality,
full app compatibility, idle/reopen behavior and installation on a second machine
still need validation. Existing kernel-source patch files are dependencies; this
work changes the installer scripts, not those patch files.

The kernel build preserves other kernels, no longer deletes the old custom kernel
at startup, and backs up existing custom boot assets before replacing them. It
refuses to rebuild the running kernel under the same release name. Boot options
are carried over from the current boot to retain root/encryption/subvolume options.
Boot-file installation is not atomic: keep a working distro kernel as fallback.
The remote kernel and OV13858 patch downloads still follow the existing builder's
workflow; this is not yet a signed distribution package or a verified release.

## Other commands

```bash
bash install-surface11.sh status
bash install-surface11.sh cameras       # Repair camera setup only
bash install-surface11.sh kernel        # Rebuild while running a different kernel
bash install-surface11.sh undo-cameras  # Remove bridge; keep native kernel drivers
```

Quit Discord through its tray menu and close camera apps before setup. Use normal
app launchers afterward and select **Surface Front Camera** / **Surface Rear Camera**.
The master command's webcam check uses temporary raw buffers that are deleted on
exit. Aim both cameras at a lit scene so it can distinguish capture from the idle
black placeholder. For details, diagnostic logs and undo behavior, see
[CAMERA-SETUP.md](CAMERA-SETUP.md).

Re-running the installer repairs stale DKMS records and the malformed quoted
camera labels created by an earlier revision. It reloads only this setup's known
loopback devices; if they are busy, it stops and asks you to quit their users.

The camera phase also installs a WirePlumber 0.5.18+ visibility policy and two
PipeWire publisher services. GNOME Camera and portal browsers receive the same
640×480 YUYV pixels as direct V4L2 apps. Rear mounting rotation is applied once in
the relay. Reopen apps after installation and select **Surface Front Camera** or
**Surface Rear Camera**; old browser device selections may need changing.
