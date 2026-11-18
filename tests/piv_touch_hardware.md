# PIV touch activation hardware checks

Host simulation validates firmware policy and descriptor contents. Before a
release, run these checks with an ESP32-S3 sensor and a Mac that has no policy
requiring smart-card login. macOS field-switch timing is not observable from USB
enumeration alone; the firmware waits for successful PIV selection plus a
configurable PIN delay (50 ms by default). Holding an enrolled finger delays
automatic entry until release within the card window.

1. Upgrade an existing paired device. Confirm `piv_touch=off`, existing PIV
   login still works, and host keys and fingerprint templates are preserved.
2. Run `tinytouch piv-touch on`, authorize, and reconnect. Confirm status reports
   `piv_touch_active=on piv_visible=no`. Confirm the idle device has HID and CDC
   interfaces and no smart-card interface in the host's USB descriptors.
3. Lock the Mac. Enter the normal password without touching tinyTouch. Confirm
   it unlocks and does not request the dummy smart-card PIN.
4. Lock again and touch an enrolled finger. Confirm the card enumerates, the
   field changes to PIN before any keystrokes, and both login and Login Keychain
   unlock. Repeat with just the display asleep, then with the Mac asleep and
   USB remote wake available. Use one touch and lift in each case. Confirm one
   `finger_matched`, then `piv_wake_sent`, card selection and a successful unlock.
   Immediately log out after login. Confirm password entry is available without
   waiting for the 20-second timeout. Touch again and confirm a second login works.
5. Try an unenrolled finger. Confirm there are no typed keys or authorized key
   operations, and the smart-card interface disappears again.
6. With the display asleep and the Mac under load, hold an enrolled finger
   until the PIN field appears. Keep holding for two more seconds. Confirm
   the field stays empty, then lift and confirm exactly one unlock.
   Repeat and keep holding until the 20-second card window expires. Confirm
   the card hides and lifting produces no keystrokes. Touch again to retry.
7. Disable the option, reconnect, and confirm continuous PIV visibility. Switch
   to HID with the option saved on and confirm normal helper authentication.
8. With the option active, pair on a second Mac. Pause over 60 seconds at the
   identity selection or administrator prompt, then continue. Confirm discovery
   renews and fresh fingerprint presence authorizes pairing after any USB reset.
9. Run enrollment and firmware staging while a visibility window expires.
   Confirm replies arrive, serial recovers, and operations are not interrupted.
10. Run `USB RECONNECT` while idle through the console. Confirm it does not
    expose the card. Factory reset and reconnect; confirm `piv_touch=off`.
