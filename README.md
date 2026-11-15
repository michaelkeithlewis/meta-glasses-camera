# Meta Glasses Camera

Meta Glasses Camera makes Ray-Ban Meta (Gen 2) glasses a normal camera on a Mac. The camera is
named **Meta Glasses**. Screen Studio, FaceTime, Zoom, QuickTime and other camera apps can choose
it. OBS is not necessary.

The glasses connection comes from
[meta-g-link-direct](https://github.com/RandyNorthrup/meta-g-link-direct) by Randy Northrup, an
OBS plugin. This project puts the same connection behind a macOS camera extension.

> **Beta.** Tested with one pair of Ray-Ban Meta Gen 2 glasses on Apple Silicon Macs (macOS 26
> and 27). This project is not affiliated with Meta or Ray-Ban.

## How it works

- **Meta Glasses.app** is a menu-bar app. The app connects to the glasses over Bluetooth. The
  glasses then start their own Wi-Fi network, and the Mac joins that network to receive the video.
- The app decodes the video and sends each picture to the **Meta Glasses** camera, a Core Media
  I/O camera extension.
- The glasses stream only while an app uses the camera. When no app uses the camera, the glasses
  stop and the Mac rejoins its usual Wi-Fi network.
- The camera is portrait 9:16 at 30 fps. Camera apps can choose 720 x 1280, 608 x 1080,
  406 x 720 or 360 x 640.

## Know before you start

- **The glasses have one owner.** Setup makes this Mac the owner of the glasses. The Meta AI phone
  app and any other Mac lose the glasses. To use the glasses with the phone again, remove the
  glasses in the Meta AI app and add them again.
- **No internet over Wi-Fi while streaming.** The Mac's Wi-Fi is on the glasses' network, which
  has no internet. Use Ethernet if the Mac must be online while it records.
- **Battery.** Streaming uses about 5% of the glasses' battery per minute.
- **Start time.** The first picture takes about 50 seconds.
- **Video only.** The camera carries no audio. Use a normal microphone in the camera app.

## Install

1. Download the latest `Meta-Glasses-<version>-macos-arm64.zip` from
   [Releases](https://github.com/michaelkeithlewis/meta-glasses-camera/releases).
2. Unzip the file.
3. Move **Meta Glasses.app** to the **Applications** folder. The camera extension works only
   from the **Applications** folder.
4. Open **Meta Glasses.app**.
5. Continue at [Set up](#set-up-one-time-per-mac).

The release build is signed with a Developer ID and notarized by Apple. The release build runs on
Apple Silicon Macs with macOS 13.3 or later.

## Requirements to build


- A Mac with Apple Silicon, macOS 13.3 or later, and Xcode.
- Ray-Ban Meta Gen 2 glasses.
- A paid Apple Developer Program membership. macOS runs a camera extension only when the extension
  is signed with a Developer ID. The release download does not need a membership.

## Build

1. Create two App IDs in your Apple Developer account. One App ID is your app bundle ID, for
   example `com.example.metaglasses`. The other App ID is the same ID plus `.camera`.
2. Enable **App Groups** on both App IDs. The group is `<TEAM_ID>.<app bundle ID>`.
3. Enable **System Extension** on the app's App ID.
4. Create a **Developer ID** provisioning profile for each App ID.
5. Save the profiles as `profiles/app.provisionprofile` and `profiles/camera.provisionprofile`.
6. Copy `config.example.env` to `config.env`.
7. Fill in `config.env` with your team ID, bundle ID, signing identity and App Store Connect API key.
8. Run the build script:

   ```
   scripts/build.sh
   ```

The script downloads meta-g-link-direct at the commit in `upstream-commit.txt` and applies
`patches/`. The script also downloads CMake if CMake is not on the `PATH`. Then the script builds,
signs, notarizes and installs `/Applications/Meta Glasses.app`.

`scripts/asc.py` is a small App Store Connect API client. You can use `scripts/asc.py` to create the
App IDs and profiles from the command line.

If you build over SSH, the login keychain is locked and `codesign` fails. Run
`scripts/gui-run.sh scripts/build.sh` to run the build in the logged-in session.

## Set up (one time per Mac)

1. Open **Meta Glasses.app**.
2. Turn on the camera extension when macOS asks. The switch is in **System Settings** >
   **General** > **Login Items & Extensions** > **Camera Extensions**.
3. Turn off Bluetooth on your phone.
4. Fold both arms of the glasses.
5. Hold the capture button for about 12 seconds, until the light blinks blue.
6. Pair the glasses in **System Settings** > **Bluetooth**. The glasses show as "RB Meta" and four
   characters.
7. Click the glasses icon in the menu bar.
8. Click **Set up glasses...**.
9. Log in to Meta in the setup window. The setup window makes this Mac the owner of the glasses.
10. Allow Bluetooth and Location for **Meta G Link Helper** when macOS asks. The helper uses
    Location only to read the name of the glasses' Wi-Fi network.
11. The first time the app connects, macOS asks for your password. Click **Always Allow**.

## Use

1. Unfold the glasses.
2. Put on the glasses.
3. In the camera app, choose the camera **Meta Glasses**.
4. Wait about 50 seconds. Until the picture comes, the camera shows "Waiting for the glasses".
5. When you finish, turn off the camera in the camera app. Folding the glasses also stops the
   stream.

The menu-bar icon is grey while the glasses are idle. The menu shows the glasses' status and
battery. **How it works...** in the menu shows these steps again.

## Troubleshooting

- If a camera app shows a black picture, choose a different camera in the app. Then choose
  **Meta Glasses** again.
- If **Meta Glasses** is missing from the camera list after an update, restart the Mac. macOS
  starts a replaced camera extension only after a restart.
- If Screen Studio says "invalid configuration", update to the latest build. Older builds offered
  only the 1280-pixel format.
- To test without the glasses, run:

  ```
  open "/Applications/Meta Glasses.app" --args --test-pattern --self-check
  ```

  The app log is `~/Library/Logs/MetaGlasses.log`. A good result is
  "camera check: 149 pictures in 5 s".

## License

AGPL-3.0, the same as meta-g-link-direct. See `LICENSE`.
