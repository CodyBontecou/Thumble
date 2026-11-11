# ConsolePort and phone settings

Open **Thumble menu → Controller settings** to see the active controller and ConsolePort sync status.

Configure abilities, button bindings, modifier assignments, camera behavior and targeting in ConsolePort/WoW. Game settings take effect in WoW. Thumble does not apply a second copy of game sensitivity or inversion.

After changing bindings, type `/reload` in WoW. With the Thumble addon installed and **Automatically sync ConsolePort** enabled in the Mac receiver, the receiver reads the saved snapshot and updates the phone’s spell labels, icons and modifier layers. This is a snapshot workflow; labels, action pages and cooldowns do not stream live.

The settings screen checks receiver status every five seconds while open and offers **Check sync status** for a manual check. That button reads the receiver’s current status; it cannot make WoW save its settings. The screen shows the last exported character, timestamp and modifier assignments, and distinguishes an active mirrored profile from a different selected controller. Older receivers show an update message. Disconnecting clears the screen’s received status.

Use **Touch stick calibration** for phone input adjustments. It applies to the built-in ConsolePort controller and automatic character mirrors. Saved custom controllers retain their own settings. Automatic sync preserves the phone’s touch geometry and mappings.

The bridge adds optional display metadata to the existing profile catalog response. It sends the character name, export timestamp, mirrored profile ID, button count, addon version, action page and modifier assignments when available. Local SavedVariables paths and character GUIDs remain on the Mac. This metadata never changes input mappings or sends commands to WoW.

## Edit the phone layout

Open **Thumble menu → Edit layout** to edit the full-size controller in place. Drag the actual buttons and sticks to move them, and drag a selected control’s orange corner to resize it. **Options** opens control settings over the layout, including movement and size buttons, custom labels, gamepad output selection, and stick dead zone, sensitivity and axis inversion. The options panel also contains **Save draft**, **Use on Mac**, and **Practice**.

Add buttons, triggers or sticks when the corresponding gamepad outputs and canvas space are available. **Practice** tests the draft locally. **Save draft** keeps it on this phone. **Use on Mac** saves and activates it on the paired receiver after validation and the phone’s layout acknowledgement. Update the Mac receiver to enable this operation.

The editor resumes the last saved phone draft. **Start from active controller** copies the current controller into a new draft. Saved Mac profiles remain available under **Controller profiles**. ConsolePort reloads refresh edited profiles’ spell artwork and modifier layers while preserving their identity, geometry, custom labels and input mappings.

## Choose WoW spells on the phone

Install the updated Thumble addon and receiver, enable ConsolePort sync, then type **/reload** in WoW outside combat. Open **Controller settings → WoW actions**, refresh the character, select a button and search its learned spells. Supported game actions are available below the spell list. The screen identifies account-wide binding scope before proposing a change.

**Copy proposal to Mac** places the reviewed proposal on the Mac clipboard. In WoW, open **/thumblebridge**, paste, choose **Review pasted plan**, then click **Apply reviewed changes** outside combat. The addon rechecks the character, scope, action page, spells and existing bindings. **Restore last bindings** remains available in the addon.

Type **/reload** after Apply, then refresh the character on the phone. A matching result is shown as **Binding confirmed** after the exported bindings match the proposal. Reserved modifier/cursor buttons and unrecognized override bindings require configuration in ConsolePort.

Haptics controls and a live game-to-phone transport remain future work.
