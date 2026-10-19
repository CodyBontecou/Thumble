# Thumble Link 0.1.0

Export your existing WoW Forever keyboard bindings into a Thumble iPhone setup.
This first version targets **Forever interface 16001** and Blizzard's default
action bars. It requires the matching Thumble Mac app/CLI from this repository.

## Install

1. Copy this entire `ThumbleLink` folder into your Forever client's
   `Interface/AddOns` directory. `ThumbleLink.toc` must be directly inside
   `Interface/AddOns/ThumbleLink`, with no extra nested folder.
2. Enable **Thumble Link** in the character-selection AddOns list and enter WoW.
3. Outside combat, type `/thumble`.
4. Select Main bar, Extra bars, and/or Utility, then click **Generate export**.
5. Copy the selected code with Cmd+C on Mac or Ctrl+C on Windows.

## Import on Mac

Click **Thumble Link…** in the Thumble Mac toolbar. Paste the code, optionally
name the setup, and choose **Review Import**, then **Create Setup**. Your paired
iPhone receives the setup through Thumble's existing connection. WoW should use
its keyboard/mouse interface for this setup.

You can also paste into the terminal:

```sh
thumble wow import --clipboard --dry-run
thumble wow import --clipboard
```

For a file or standard input:

```sh
thumble wow import export.txt --dry-run --json
thumble wow import export.txt --name "My Warrior"
cat export.txt | thumble wow import -
```

Re-export after changing your WoW bindings. Importing again refreshes the same
character setup, even if you renamed it. Phone positions, styling, deleted controls,
and manually edited labels/outputs survive refresh. A changed imported binding
updates unless you edited its phone output. An unavailable/removed binding clears
an unchanged imported output. Refresh does not change WoW bindings.

## First-version limits

- Configuration snapshots only. No background connection, live character/form
  detection, cooldowns, or ability pictures. Icon file IDs are retained as metadata;
  they are not image files and are not rendered by this version.
- Main-bar labels describe the page/form active at export time. The same key may
  invoke a different action after WoW changes pages or forms.
- Blizzard bars and common utility commands only. Custom action bars,
  click-casting, pet/vehicle/override bars, and native gamepad layers need adapters.
- Unbound, mouse-wheel, mouse-button, and gamepad-only actions are shown as skipped.
  A supported secondary keyboard binding is used when the primary is unsupported.
- Keyboard output uses Mac physical key positions based on a US layout. Check
  punctuation on other layouts. Cmd/Alt combinations keep their modifier meanings.
- Export selected bars that you actually need. Large imports may need rearranging
  in the editor; refresh can add new controls without moving your existing ones.
- Exports include character GUID, name, realm, class, client build, timestamp,
  command names, and action metadata. Treat the code as your character configuration.

The addon never sends gameplay commands, rewrites bindings, exports macro bodies,
opens network connections, or requires SavedVariables. Each phone press uses the
existing Thumble key-down/key-up input path.

This implementation has mocked exporter/importer coverage. Installation and key
behavior still need acceptance testing in the exact Forever client build.
