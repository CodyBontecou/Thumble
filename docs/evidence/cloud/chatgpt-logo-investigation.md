# ChatGPT logo investigation — October 23, 2026

Status: the connected **Thumble Pilot Cloud** entry still displays ChatGPT's
generated placeholder. The requested visible logo change is not complete.

## Confirmed observations

- Connected developer app: `asdk_app_6adc04482ed081918fc10f8bb3dc6325`;
  plugin entry: `plugin_asdk_app_6adc04482ed081918fc10f8bb3dc6325`.
- Public PNG asset URLs passed live byte comparisons during deployment.
- Downloading the saved 1.0.2 package from ChatGPT returned the exact PNG,
  SHA-256 `6eae962eb6ad8037b0d661bacdc8e1920825028aecfcc5fb05124fbcc07427a7`,
  and all four interface fields: `logo`, `logoDark`, `composerIcon`,
  `composerIconDark`, each referencing `./assets/icon.png`.
- The rendered directory header uses a built-in 24px SVG data URI, enlarged
  to 58px, instead of the packaged PNG. Reloading did not change that.
- Revision 1.0.3 duplicated the PNG at `.codex-plugin/assets/icon.png` to
  test manifest-relative resolution. Revision 1.0.4 additionally placed
  name/version before interface in the manifest. Both were accepted and
  displayed their new version numbers; neither changed the logo.
- Refresh tools completed on the existing developer app without resolving
  the directory logo. The connection and OAuth settings were not replaced.
- The developer app's available Manage controls edit name and description,
  refresh tools, or delete the app. The name editor has no image field.
- A separate **Thumble** developer-dashboard draft exists in Isotech:
  `plugin_asdk_app_6adc07c8d6f08191812f87b55c8525b5`, version 0.1.1.
  Its dashboard renders a 1024px image at 48px and its source package
  references `./assets/icon.png`. It is not the connected pilot registration.
  Its configuration remains incomplete; this investigation did not change it.
- Direct dashboard access to the connected pilot reports **Plugin not found
  in this organization** under Isotech. Personal reports that the current role
  needs `api.apps.read` to manage plugins. Personal's upload action also
  presented a developer identity verification requirement.

## Interpretation and remaining work

The image is not lost during ZIP upload. The unresolved boundary is applying
packaged branding to ChatGPT's generated developer-app entry. A registration
override or a platform importer/rendering defect is plausible, but its exact
implementation cause is not established from the available UI. Do not claim
that another server deployment, file rename, or reconnect will fix it.

Further repair needs management access to the owning pilot registration or
an explicit decision to replace the developer entry with a normal packaged
integration. No roles were changed, identity documents submitted, apps deleted,
or replacement connections created during this investigation.
