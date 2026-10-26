import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { join } from 'node:path';

export function privateWindowsAcl(value) {
  if (!value || typeof value.sid !== 'string' || !/^S-1-[0-9-]+$/.test(value.sid) || value.protected !== true || !Array.isArray(value.rules) || !value.rules.length) return false;
  const owners = [value.sid, 'S-1-5-18', 'S-1-5-32-544'];
  return owners.includes(value.owner) && value.rules.some(rule => rule.sid === value.sid && rule.type === 'Allow') && value.rules.every(rule =>
    rule.type === 'Deny' || (rule.type === 'Allow' && [value.sid, 'S-1-5-18'].includes(rule.sid) && rule.inherited === false));
}

export async function checkWindowsPairingFile(path) {
  // Fixed script; the path is data in a child-only environment variable.
  const script = `$ErrorActionPreference='Stop'; $acl=Get-Acl -LiteralPath $env:THUMBLE_PAIRING_FILE; $sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value; $rules=@($acl.Access | ForEach-Object { @{sid=$_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value;type=$_.AccessControlType.ToString();inherited=$_.IsInherited} }); @{sid=$sid;owner=$acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value;protected=$acl.AreAccessRulesProtected;rules=$rules} | ConvertTo-Json -Compress -Depth 5`;
  const { stdout } = await promisify(execFile)(join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
    ['-NoProfile', '-NonInteractive', '-Command', script], { windowsHide: true, timeout: 5000, maxBuffer: 65536, env: { ...process.env, THUMBLE_PAIRING_FILE: path } });
  const acl = JSON.parse(stdout.replace(/^\uFEFF/, '').trim());
  if (!privateWindowsAcl(acl)) throw Object.assign(Error('Pairing file is not private'), { acl });
}
