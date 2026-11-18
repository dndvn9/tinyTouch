# One tinyTouch on several Macs

## Install and pair

1. Install the matching build of **tinyTouch.app** in Applications on each Mac running macOS 13 or later. Move the app there before setup so the login agent has a stable executable path.
2. Connect the ESP32-S3 to the Mac with a USB data cable. Open the app, choose the serial number printed in the device selector and select **PIV smart card** for native authentication.
3. Select **Set up this Mac**. Enroll a finger if the sensor is empty. Approve the requested touches and macOS account or smart-card prompts. Repeat setup once on each additional Mac or account. An existing PIV identity should be reused across Macs. Do not generate a replacement identity to add a computer.
4. Unplug the device, reconnect and test a compatible prompt before relying on it at login. The app can be closed after setup. The PIV path is driven by macOS. In HID mode a per-user launch agent starts at login, watches USB and reconnects when the device returns after sleep.

The selected authentication mode is a device setting shared by all Macs. Switching modes on one Mac affects the others. The **Fingerprints**, **Enroll** and **Delete** actions operate on the device's shared sensor inventory.

## HID fallback and host removal

Choose HID explicitly on each Mac that needs keyboard fallback. Enter that account's password in the setup dialog and approve Keychain access. This registers one of eight HID host slots. The Mac stores its own pairing secret and password in the login Keychain. The ESP32 receives the password temporarily to type it into the focused field. Its persistent registry contains pairing keys. It does not store the account password.

Focus the intended password field before touching. Newly configured secure HID helpers require macOS Secure Event Input before they release a password. That signal is system-wide and does not identify the destination field or application. Some password prompts do not enable it. Use the normal macOS authentication method in that case. If the Mac password changes, choose HID and use **Update HID password** on that Mac.

**Paired HID Macs** displays opaque IDs. Record the ID when adding a Mac, select the intended device, then use **Revoke** with that host ID. An exhausted registry requires explicit removal. Native smart-card associations are local to each Mac and must be removed from the corresponding account through its smart-card settings or the administrator's sc_auth workflow. Removing a HID host has no effect on its native PIV pairing.

## Firmware and compatibility

Choose **Update firmware from file…**, select the signed OTA application binary and approve the touch. Reconnect after staging and check **Device status**. Use a signed production image compatible with the board and its existing signing key. Firmware OTA preserves enrollment and registry data. See the [update and recovery instructions](update.md).

Status reports protocol 6 and the optional pair_wrap capability. Re-run HID setup once on an existing Mac after upgrading firmware and helper to opt in to live device proof. Old helpers and firmware support the existing protocol. Perform initial enrollment over a direct USB link under your control. The ephemeral key exchange has no independent manufacturer trust anchor and cannot establish first-contact device identity through an untrusted proxy.

Login, unlock, sudo and authorization dialogs depend on macOS accepting PIV for that operation. The app uses the system smart-card pairing flow and leaves PAM and FileVault configuration under administrator control. A per-user launch agent is available after user login. FileVault preboot and Apple Touch ID have different requirements. See [Apple's FileVault and smart-card guide](https://support.apple.com/guide/deployment/dep806850525/web).

## Build from this checkout

Use ESP-IDF 5.3.x. The project expects a signing key at firmware/tiny_touch_unified/secure_boot_signing_key.pem. For a development board with no existing key, create a local test key once with the command below. Use the original signing identity when upgrading a deployed device. From an initialized IDF shell run these commands from the repository root.

```sh
test -e firmware/tiny_touch_unified/secure_boot_signing_key.pem || espsecure.py generate_signing_key --version 2 firmware/tiny_touch_unified/secure_boot_signing_key.pem
idf.py -C firmware/tiny_touch_unified build
```

On a Mac with Xcode command-line tools and Python 3.13 available, build the standalone backend, select a new output path for the application, then verify its signature. Use the project's stable signing identity for distribution. Ad-hoc signatures are suitable for local development and may require reauthorizing Keychain when the binary changes.

```sh
TINYTOUCH_SIGNING_IDENTITY=- TINYTOUCH_ALLOW_ADHOC=1 release/build-standalone-macos.sh
bash macos/Manager/build.sh build/distribution/bin/tinytouch dist/tinyTouch.app
codesign --verify --deep --strict dist/tinyTouch.app
python3.13 -m venv .venv
.venv/bin/python -m pip install -r macos/requirements.txt
.venv/bin/python -m unittest discover -s tests
```

To exercise the firmware key exchange against the Python cryptography implementation on macOS, build native mbedTLS 3.6 and run the test with its include directory and library path.

```sh
.venv/bin/python tests/host/pairing/interop.py /path/to/mbedtls/include /path/to/libmbedcrypto.dylib
```

## Hardware acceptance

Use two Macs with distinct accounts and one ESP32-S3. Pair the same card on both, unplug it from A, connect it to B, authenticate, then return to A. Test login, unlock and a smart-card-enabled sudo policy separately. For HID, keep a distinct account password on each Mac, test sleep and reboot after account login, verify a normal text editor receives no password, revoke B, then confirm A still works and B stops. Check an interrupted OTA and a normal signed upgrade on a spare board. Keep a working account recovery method throughout the hardware test.
