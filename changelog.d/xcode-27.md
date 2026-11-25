### Internal
- CI runs on Xcode 27.2 (GitHub's `xcode-27` image), and both Xcode Cloud workflows are pinned to Xcode 27.2 with it. From April 2027 Apple accepts only uploads built with the iOS 27 SDK (ITMS-90725). CI and the release build move together so the tests keep checking the toolchain that ships.
