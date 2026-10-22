#!/usr/bin/env python3
"""Generate a managed override from the INSTALLED WirePlumber portal policy.

Keep its permission-store checks and portal gating intact. A separate NONE match
cannot veto its Camera grant because PermissionManager combines matches with OR.
"""
from pathlib import Path
import sys


def prepare(source):
    signature = '  function (_, client, _)\n'
    anchor = '    local client_id = client["bound-id"]\n'
    camera_interest = '    Constraint { "media.role", "=", "Camera" },'
    if (source.count(signature) != 1 or source.count(anchor) != 1
            or source.count(camera_interest) != 1):
        raise ValueError('Unsupported WirePlumber portal policy; refusing an unverified override.')
    source = source.replace(signature, '  function (_, client, object)\n')
    veto = '''    -- The libcamera SPA source overwrites media.role with Camera at runtime.
    -- Veto these backends IN the portal grant, before its normal permission checks.
    local name = object:get_property ("node.name")
    if name == "libcamera_input.__SB_.PC00.I2C5.CAMF" or
        name == "libcamera_input.__SB_.PC00.I2C3.CAMR" then
      return Perm.NONE
    end
'''
    return '-- Managed by surface11-camera; regenerated from the installed package.\n' + source.replace(anchor, veto + anchor)


if __name__ == '__main__':
    try:
        Path(sys.argv[2]).write_text(prepare(Path(sys.argv[1]).read_text()))
    except (OSError, ValueError, IndexError) as exc:
        raise SystemExit(str(exc))
