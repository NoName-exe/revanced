#### ⚠️ Do not download modules from 3rd party sources like random websites you found on Google. Only use this repository. I am not responsible for anything they may contain.

# ReVanced 
[![Build Modules](https://github.com/NoName-exe/revanced/actions/workflows/build.yml/badge.svg)](https://github.com/NoName-exe/revanced/actions/workflows/build.yml)
[![CI](https://github.com/NoName-exe/revanced/actions/workflows/ci.yml/badge.svg?event=schedule)](https://github.com/NoName-exe/revanced/actions/workflows/ci.yml)

Get the [latest CI release](https://github.com/NoName-exe/revanced/releases/latest).

## Features
 * Updated with the latest versions of patches.
 * Cleans APKs from unneeded libs to make them smaller.
 * Fully open-source, every binary or APK is compiled without human intervention.
 * Modules:
     * Recompile invalidated odex for YouTube and YouTube-Music for faster usage.
     * Receive updates from Magisk app.
     * Should not break safetynet or trigger root detections used by certain apps.
     * Handle installation of the correct version of the stock app and all that.

 ## Notes
* YouTube Magisk Module is installed as a system app and requires a reboot to install/update.
* YouTube-Music Magisk Module is installed as a user app and does not require a reboot to install/update.
* Use [mindetach](https://github.com/j-hc/mindetach-magisk) to block Play Store from updating YouTube and YouTube-Music.
* Non-root versions of YouTube and YouTube-Music require [Vanced MicroG](https://github.com/inotia00/VancedMicroG/releases/latest) to work.

# Credits
[j-hc](https://github.com/j-hc) for [mindetach](https://github.com/j-hc/mindetach-magisk) and the [script on which this is based on](https://github.com/j-hc/revanced-magisk-module).

[HuskyDG](https://github.com/HuskyDG) for his [Magisk Module Template](https://github.com/HuskyDG/revanced-build-ci) that installs YouTube as a system app.

[ReVanced Team](https://github.com/revanced) for their [patches](https://github.com/revanced/revanced-patches) and everything else that they do.

[inotia00](https://github.com/inotia00) for [Vanced MicroG](https://github.com/inotia00/VancedMicroG).

[Gnad Gnaoh](https://github.com/gnadgnaoh) for helping me figure some stuff out.