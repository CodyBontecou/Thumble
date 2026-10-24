# Thumble

Language for controller design, delivery and play.

## Controller design

**Profile**: A named controller layout containing controls and their mappings to gamepad outputs.

**Profile revision**: An immutable saved version of a profile.

**Cloud delivery**: A request to send one specific profile revision to one registered phone.

**Render receipt**: A phone's report that its controller renderer committed the requested profile revision. It does not establish that a Mac or game received input.

**Receiver activation**: The Mac receiver's selection and delivery of a controller layout for its paired phone's gameplay session.
