"""Diagnose the real native attach result before the end-to-end XInput gate."""
import subprocess

from vgamepad.win import vigem_client as client, vigem_commons as common
from vgamepad.win.virtual_gamepad import VBUS

target = client.vigem_target_x360_alloc()
try:
    result = client.vigem_target_add(VBUS.get_busp(), target)
    print(f'Native Xbox attach: {common.VIGEM_ERRORS(result).name} (0x{result:08x})', flush=True)
    attached = client.vigem_target_is_attached(target)
    print(f'Native Xbox attached: {attached}', flush=True)
    if not attached:
        subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
            "Get-CimInstance Win32_PnPEntity | Where-Object { $_.DeviceID -match 'VID_045E|VIGEM' } | Format-List Name,DeviceID,Status,ConfigManagerErrorCode"],
            check=False, timeout=30)
        raise RuntimeError('Native Xbox controller did not attach; see SDK and PnP diagnostics above')
finally:
    client.vigem_target_remove(VBUS.get_busp(), target)
    client.vigem_target_free(target)
