# DroidDeck on Mali (Pixel 9 Pro) through Venus

Handoff notes for the next session.
Upstream DroidDeck 0.3.1 runs on Adreno only.
This branch makes it run on the user's Pixel 9 Pro (Tensor G4, Mali-G715, Android 17).

## Status (2026-10-08)

Prototype 11 runs Steam Big Picture with a clean, live picture.
The user signed in and played Slay the Spire 2 at about 40 fps.

Open problems:
- Hollow Knight Silksong (Unity, D3D11 through DXVK) exits during startup. Logs: session `2026-10-08-14-steam`.
  - DXVK creates its Vulkan instance, then the game exits before any swapchain.
  - Proton turns DXVK logging off, so the reason is not in the session logs.
  - Next: read Unity's `Player.log` in the prefix, under `AppData/LocalLow/Team Cherry/Hollow Knight Silksong/`.
  - Suspects: no BCn and no geometry shaders on Mali, which D3D11 feature level 11 needs.
- Steam's UI blocks 30 s at a time on `IClientFriends::GetVoiceMicrophoneVolume`.
  - A game launch looks stuck on "Launching" for that long, even after the game has died.
- Mali has no BCn texture compression, so many DXVK games will break.
- The render server aborts ("pthread_mutex_lock called on a destroyed mutex") when a context dies after an error. Not fixed.
- The phone runs short of memory: about 1 GB free and swap nearly full during a session.
- Performance is unmeasured beyond the on-screen fps.
  - gamescope now uploads every Xwayland frame into a new texture (patch 0114).
  - The shared memory is uncached, so CPU reads of it are slow.
- Prototypes 7 to 11 are debuggable (`debuggable true` in `app/build.gradle`, uncommitted) so `adb run-as` works.
  - Android shows a harmless "not 16 KB-compatible" dialog because of it.
  - Remove before any real release.

## Where things are

- **Source:** `C:\Users\derab\source\repos\DroidDeck`, branch `mali-venus` (off tag `0.3.1`).
- **Remote:** `mine` = https://github.com/DavidCimo/droiddeck-mali. It's public; the user made it public to download on the phone.
  - The gh account is `DavidCimo`.
  - Releases `mali-venus-proto1`…`proto6` hold the APKs. Proto 7 to 11 were installed over ADB only.
- **Build outputs:** `C:\Users\derab\source\repos\droiddeck-mali\`
  - `DroidDeck-0.3.1.apk`: the official APK. Prebuilt assets and proot come from it.
  - `venus-out/`: the Mesa Venus ICD.
  - `libblsession.so`: the session preload with `venus.c`.
  - `gamescope`: gamescope 3.16.29 with the app's patches plus 0114.
  - `venus.patch`: the source diff the APK build applies.
  - `DroidDeck-0.3.1-mali-venus-<n>.apk`: the builds.
- **WSL Ubuntu** (`wsl -d Ubuntu`, user `delo`; use `-u root` for apt, there's no passwordless sudo):
  - `/home/delo/android-sdk`: SDK, NDK 27.3.13750724, CMake 3.22.1, build-tools 34.
  - `/home/delo/mali`: virglrenderer 1.3.0 (patched), Mesa 26.2.4 checkout, libepoxy, Vulkan-Headers, `android-out/`.
  - `/home/delo/DroidDeck`: the clean LF clone the APK is built in.
- **ADB:** `C:\Users\derab\tools\platform-tools\adb.exe`, paired with the Pixel over wireless debugging.

## How it works

The session's Linux processes (glibc) cannot load Mali's Android (bionic) Vulkan driver.
Venus bridges them:

1. The guest loads Mesa's Venus ICD (`libvulkan_virtio.so`) with `VN_DEBUG=vtest`.
2. The ICD serializes Vulkan calls over a unix socket: `files/venus/vtest.sock`.
3. virglrenderer's `virgl_test_server --venus --no-virgl` runs on the Android side as an app child process.
4. Per client, it forks `virgl_render_server`, which replays the calls on Mali's system Vulkan driver.

The app's own compositor uses Mali's system driver directly.

## Changes on the branch

App (Kotlin/C):
- `session/VenusComponent.kt` (new): on a non-Adreno GPU, starts the vtest server and stages the ICD to `files/venus/`.
  - It sets the guest env: `VK_ICD_FILENAMES`, `VN_DEBUG=vtest`, `VTEST_SOCKET_NAME`, `MESA_VK_WSI_DEBUG=sw`.
- `session/SessionService.kt`: uses the Venus env instead of the Turnip ICD, and adds the component.
- `gpu/TurnipDriver.java`: the compositor uses the system Vulkan driver on non-Adreno.
- `cpp/waylandcomp/src/vk_present.c`:
  - Enables only the dma-buf extensions the driver has.
  - Logs the driver's full extension list.
  - Gives a zero row pitch a packed 64-byte row (gamescope's 1x1 root buffer).
- `gpu/GpuInfo.kt`, `MainActivity.kt`, `core/DeviceReport.kt`: wording, plus a "Venus" line in `device.txt`.
- `tools/linuxfs/preload/venus.c` (new, part of `libblsession`): unsets `LIBGL_KOPPER_DISABLE` when `VN_DEBUG` has `vtest`.
  - Steam's `steamwebhelper.sh` sets it unconditionally.
  - Without kopper and without DRI3, Zink gets no GL context, and the Steam UI crash-loops.
  - Steam restores that script when it verifies its install, so it cannot be edited.

`tools/venus/mesa-venus-vtest.patch` (Mesa 26.2.4, guest side):
- No `VK_EXT_physical_device_drm` under vtest. gamescope otherwise demanded a primary node.
- Sync-fd export for fences and semaphores under vtest: a CPU wait that returns -1 (already signaled). gamescope requires `VK_KHR_external_semaphore_fd`.
- WSI skips attaching a -1 sync file to a dma-buf.

`tools/venus/virglrenderer-android.patch` (virglrenderer 1.3.0, host side):
- Mali on Android can import dma-bufs but cannot export any memory.
  - Buffers report dma_buf features 0x4 (importable only); opaque fd reports nothing.
  - virglrenderer's minigbm fallback does not exist on Android.
- On Android the server allocates the dma-buf itself and imports it.
  - Source: `/dev/dma_heap/system-uncached`, then `/dev/dma_heap/system`, then an `AHardwareBuffer` fd.
  - Uncached because Mali here is not cache-coherent with the CPU, and nobody calls `DMA_BUF_IOCTL_SYNC`.
  - The guest maps all host-visible memory as coherent, and vtest's flush and invalidate do nothing.
  - On the cached heap, frames tore at cache-line granularity: the streaks.
  - The fd rides the existing udmabuf plumbing.
- Image and buffer queries report "importable dma-buf" as exportable too. gamescope keeps only exportable modifiers.
- Exports of any memory type go through that allocator.
- Logs what the driver reports, and failed allocations.

`tools/gamescope/patches/0114-shm-buffers-upload-every-commit.patch`:
- Xwayland has no glamor here, so it reuses about three wl_shm buffers with new pixels.
- gamescope cached one texture per buffer, copied at first import.
- The screen cycled through three stale frames: the flicker. Input and audio still worked.
- The patch caches dma-buf textures only, and uploads shm buffers on every commit.
- See `tools/gamescope/PATCHES.md`.
- The session stages gamescope from the APK assets every start, so it needs an APK rebuild.

## Build

Run each step after its inputs change:

1. Android side (WSL): `bash /mnt/c/Users/derab/source/repos/DroidDeck/tools/venus/build-virgl-android.sh`
   - It does a full clean rebuild; `ninja -C /home/delo/mali/virgl-build install` is enough for code changes.
   - After editing `/home/delo/mali/virglrenderer`, refresh the patch: `git -C /home/delo/mali/virglrenderer diff > .../tools/venus/virglrenderer-android.patch`.
2. Guest ICD (Git Bash, Docker Desktop running): `MSYS_NO_PATHCONV=1 bash tools/venus/build-venus-icd.sh`
3. Preload (Git Bash, Docker): `MSYS_NO_PATHCONV=1 bash tools/venus/build-libblsession.sh`
4. gamescope (Git Bash, Docker): `MSYS_NO_PATHCONV=1 bash tools/venus/build-gamescope.sh`
   - Emulated arm64, so it takes most of an hour.
   - Prototype 11's binary came from the same steps run by hand; the script itself has not run yet.
5. Source patch (Git Bash): `git diff 0.3.1 > ../droiddeck-mali/venus.patch`
   - Run `git add -N` on new files first.
6. APK (WSL): `bash /mnt/c/Users/derab/source/repos/DroidDeck/tools/venus/build-apk.sh <n>`

Gotchas:
- Run Docker from Git Bash, not WSL: Docker Desktop's WSL integration is off.
- Prefix Git Bash commands with `MSYS_NO_PATHCONV=1`, or paths given to `wsl`, `docker` and `adb` get mangled.
- `adb pull` needs a Windows path as its target.
- The APK is signed with the project's public test key, so it installs over earlier prototypes but not over the official app.
- Use `git -c core.autocrlf=false -c core.eol=lf archive` to export files for a Linux build; plain `git archive` writes CRLF.

## Test loop over ADB

```sh
A=/c/Users/derab/tools/platform-tools/adb.exe; export MSYS_NO_PATHCONV=1
$A mdns services                     # find the phone's connect port if it dropped
timeout 300 $A install -r "C:/Users/derab/source/repos/droiddeck-mali/DroidDeck-0.3.1-mali-venus-<n>.apk"
$A shell am force-stop com.droiddeck.launcher
$A shell monkey -p com.droiddeck.launcher -c android.intent.category.LAUNCHER 1
$A shell input tap 897 1064          # "Play Steam" on the main page
$A exec-out screencap -p > shot.png
```

- The phone must be awake and unlocked, or `adb install` hangs.
- Tap "Play Steam" only once MainActivity is the top resumed activity; an earlier tap is lost.
- Wrap a remote `run-as ... sh -c` command in double quotes as one argument, or adb splits it.
- Session logs: `/sdcard/Download/DroidDeck/<newest>/`
  - `session.log`: gamescope and Steam stdout.
  - `venus.log`: the vtest and render servers.
  - `wayland.log`: the compositor; frames on screen and windows open.
  - `events.jsonl`: `frame.first` means the loading overlay lifted.
  - `crash.log`.
- Steam's own logs, live: `$A shell run-as com.droiddeck.launcher sh -c 'cd files/linuxfs/root/.local/share/Steam/logs; ...'`
  - The useful ones are `webhelper.txt`, `webhelper_gpu.txt` and `cef_log.txt`.
- The session script copies those logs into `<session>/steam/` only on a clean exit: tap Cancel (2710,1165), not force-stop.
- `Download/droiddeck-env` (KEY=VALUE lines) adds guest env without a rebuild. It is currently absent; remove it after experiments.
- First Steam start downloads and unpacks about 670 MB. On later starts Steam "verifies" and re-extracts changed files.

## Failure history (prototype → cause → fix)

1. Official APK installed → Turnip ICD, no GPU → install the prototype.
2. gamescope: "physical device has no primary node" → Mesa: drop `EXT_physical_device_drm` under vtest.
3. gamescope: missing `VK_KHR_external_semaphore_fd` → Mesa: CPU-wait sync-fd export.
4. Hang on loading: server "minigbm_allocation is not enabled" → virgl: relax the export check. Not enough: Mali exports nothing.
5. Same hang → virgl: allocate a dma-buf (dma-heap or AHB) and import it.
6. gamescope assert `modifiers.size() > 0` → virgl: report importable dma-buf as exportable; route exports through the allocator.
7. Updater "zink: could not create swapchain"; Xwayland has no glamor, so no DRI3 → `MESA_VK_WSI_DEBUG=sw`.
8. steamwebhelper restart loop, "failed to acquire a gl context" → `venus.c` preload unsets `LIBGL_KOPPER_DISABLE`.
9. Frames reach the compositor but "0 windows open" and the overlay stays → compositor: fix stride 0 on gamescope's 1x1 root buffer.
10. Sign-in screen shows, with dash streaks across it → virgl: allocate from the uncached dma-heap.
11. Picture looks frozen or flickers between old frames, though clicks play sounds → gamescope patch 0114.
12. Steam sign-in and Slay the Spire 2 at about 40 fps (current).

## Next steps

- Never enter credentials for the user. They type the password and handle Steam Guard themselves.
- Try heavier games, then read Proton/DXVK output in `session.log` and `venus.log`.
- Likely next blockers: BCn textures (DXVK needs them, Mali has none), geometry shaders, `gl_ClipDistance`.
  - Vortek (Winlator) handles these with emulation, which would need porting into virglrenderer or a Vulkan layer.
- Fix the render server's destroyed-mutex abort on context teardown.
- Measure the cost of patch 0114 and the uncached heap, if fps matters.
- Before sharing builds widely: drop `debuggable true` and publish a release.
