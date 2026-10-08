# DroidDeck on Mali (Pixel 9 Pro) through Venus

Handoff notes for the next session.
Upstream DroidDeck 0.3.1 runs on Adreno only.
This branch makes it run on the user's Pixel 9 Pro (Tensor G4, Mali-G715, Android 17).

## Status (2026-10-08, evening)

Prototype 12 is the APK on the phone, a release build (not debuggable).
Steam Big Picture shows a clean, live picture, and Slay the Spire 2 runs at about 40 fps.

Direct3D 9-11 games run through DXVK.
Test game: Hollow Knight Silksong (Unity, D3D11), app id 1030300. In game at 30-40+ fps depending on the scene, stable, with good audio (2026-10-08).
- Prototype 12 as installed: 35-40 fps. The phone was not throttling.

Done and verified on the phone:
- The Mali compatibility layer (`tools/venus/layer`) loads and reports the six features DXVK requires.
- DXVK accepts the GPU and creates its device. D3D11 runs at feature level 11_0.
- Silksong loads and plays.
- Prototype 12 carries the layer and the queue-lock Venus ICD; nothing on the phone is installed by hand any more.

Fixed: a crash in the Venus guest driver, about 20 s after launch, with a black screen until then.
- Where: `vtest_vcmd_submit_cmd2` (`src/virtio/vulkan/vn_renderer_vtest.c`), on the `dxvk-submit` thread inside `vkQueueSubmit2`.
- What: it reads `batch->syncs[1]->sync_id` and `syncs[1]` is the pointer `0x1`.
- Cause: two threads submit to the same queue at once.
  - Venus's async present thread (`vn_wsi`) makes the WSI submits. On vtest, `vn_wsi_fence_wait` drops the queue lock while it waits on a fence.
  - It assumes one submit per swapchain. But `wsi_queue_submit2_unordered` makes a second, empty submit for DXVK's present fence.
  - DXVK's thread passes `vn_wsi_flush` in that window and submits at the same time.
  - Both use the per-queue scratch buffer `queue->storage`. The empty submit's `sync_vals[0] = 1` lands on DXVK's `syncs[1]`.
  - gamescope and Zink use no present fences, so Steam and Slay the Spire 2 never hit it.
- Fix: `vn_queue_submit` holds a new per-queue `submit_mutex`. Verified with Silksong.

Other open problems:
- Steam's UI blocks 30 s at a time on `IClientFriends::GetVoiceMicrophoneVolume`. A launch looks stuck on "Launching" even after the game died.
- The render server aborts ("pthread_mutex_lock called on a destroyed mutex") when a context dies after an error. Not fixed.
- The phone runs short of memory: about 1-2 GB free during a session. BC decoding makes textures 4-8x bigger.
- Performance is unmeasured beyond the on-screen fps.
  - gamescope uploads every Xwayland frame into a new texture (patch 0114).
  - The shared memory is uncached, so CPU reads of it are slow.
- Prototype 12 is not debuggable, so `adb run-as` fails and the hand-install loop below does not work.
  - To debug again: add `debuggable true` to the `release` build type in `app/build.gradle`, rebuild, reinstall. Keep it out of commits.
  - A debuggable build shows a harmless "not 16 KB-compatible" dialog.

## State outside the repo and the APK

On the phone, changed by hand (read this before testing anything):
- `/sdcard/Download/droiddeck-env` holds `PROTON_LOG=1`. Every game writes a full Proton log to `/root/steam-<appid>.log`.
  - Delete it when debugging is done: `adb shell rm /sdcard/Download/droiddeck-env`.
- `/data/local/tmp` holds copies of the pushed files and `watch-maps.sh`.

Not published: prototypes 7 to 12 as GitHub releases. Prototype 12's would be:
`gh release create mali-venus-proto12 -R DavidCimo/droiddeck-mali --prerelease --target mali-venus --title "0.3.1 + Venus prototype 12" --notes "…" "C:/Users/derab/source/repos/droiddeck-mali/DroidDeck-0.3.1-mali-venus-12.apk"`
It needs the branch pushed to `mine` first.

## Where things are

- **Source:** `C:\Users\derab\source\repos\DroidDeck`, branch `mali-venus` (off tag `0.3.1`).
- **Remote:** `mine` = https://github.com/DavidCimo/droiddeck-mali. It's public; the user made it public to download on the phone.
  - The gh account is `DavidCimo`.
  - Releases `mali-venus-proto1`…`proto6` hold the APKs. Proto 7 to 12 were installed over ADB only.
- **Build outputs:** `C:\Users\derab\source\repos\droiddeck-mali\`
  - `DroidDeck-0.3.1.apk`: the official APK. Prebuilt assets and proot come from it.
  - `venus-out/`: the Mesa Venus ICD.
  - `layer/`: the Mali compatibility layer and its manifest.
  - `libblsession.so`: the session preload with `venus.c`.
  - `gamescope`: gamescope 3.16.29 with the app's patches plus 0114.
  - `venus.patch`: the source diff the APK build applies.
  - `DroidDeck-0.3.1-mali-venus-<n>.apk`: the builds.
- **WSL Ubuntu** (`wsl -d Ubuntu`, user `delo`; use `-u root` for apt, there's no passwordless sudo):
  - `/home/delo/android-sdk`: SDK, NDK 27.3.13750724, CMake 3.22.1, build-tools 34.
  - `/home/delo/mali`: virglrenderer 1.3.0 (patched), Mesa 26.2.4 checkout (patched), libepoxy, Vulkan-Headers, `android-out/`.
  - `/home/delo/DroidDeck`: the clean LF clone the APK is built in.
  - The Edit and Read tools open WSL files at `\\wsl.localhost\Ubuntu\home\delo\...`.
- **ADB:** `C:\Users\derab\tools\platform-tools\adb.exe`, paired with the Pixel over wireless debugging.
- **DXVK source** for reference: `git clone https://github.com/doitsujin/dxvk` at commit `25ca63f17f34` (v3.1.1-27), the one in Proton Experimental ARM64 11.0-20260924.
  - Its shader compiler is the `subprojects/dxbc-spirv` submodule.

## How it works

The session's Linux processes (glibc) cannot load Mali's Android (bionic) Vulkan driver.
Venus bridges them:

1. The guest loads Mesa's Venus ICD (`libvulkan_virtio.so`) with `VN_DEBUG=vtest`.
2. The ICD serializes Vulkan calls over a unix socket: `files/venus/vtest.sock`.
3. virglrenderer's `virgl_test_server --venus --no-virgl` runs on the Android side as an app child process.
4. Per client, it forks `virgl_render_server`, which replays the calls on Mali's system Vulkan driver.

For Wine games, the Mali compatibility layer sits between DXVK (via winevulkan) and the Venus ICD.

The app's own compositor uses Mali's system driver directly.

## Mali compatibility layer (`tools/venus/layer`)

Why: DXVK 3.1.1 refuses any GPU without six features, and Mali-G715 has none of them.
The list comes from `dxvk/dxvk_device_info.cpp`, `getFeatureList`, compared with `vulkaninfo` through Venus.
Everything else DXVK requires is present: Vulkan 1.4, geometry and tessellation shaders, maxPushConstantsSize 256.

What it does, per feature:
- `fillModeNonSolid`: LINE and POINT polygon modes draw as FILL.
- `multiViewport`: reports maxViewports 16. Pipelines and `vkCmdSet{Viewport,Scissor}[WithCount]` keep only the first.
- `robustBufferAccess2`: the device gets `robustBufferAccess` (version 1) instead.
- `shaderClipDistance`: emulated per pipeline.
  - The last pre-rasterization stage writes the distances to a free varying location.
  - The fragment shader reads them and runs `OpKill` when one is negative.
  - Only when that stage is the only one using distances and the fragment shader's code is known.
  - Otherwise the distances are dropped. Depth-only passes lose clipping too.
  - DXVK passes shader code inline (`VkShaderModuleCreateInfo` in the stage), so its pipelines qualify.
  - Mali has no `graphicsPipelineLibraryIndependentInterpolationDecoration`, so DXVK compiles whole pipelines and the layer sees both stages.
- `shaderCullDistance`: dropped.
- `textureCompressionBC`: BC1-BC7 images are created as RGBA8, R8, RG8 or RGBA16F.
  - Every upload into one is decoded on the CPU with `bcdec` while the copy is recorded.
  - The source must be memory the application has mapped; DXVK's staging memory is.
  - Decoded texels go through the layer's own staging buffers, recycled when the command buffer is reset.
  - Copies from a BC image into a buffer, and between BC and uncompressed images, are skipped with a warning.

Files:
- `layer.c`: loader plumbing, feature and limit reporting, device creation, the hook table.
- `pipeline.c`: pipelines, shader modules, viewports.
- `spirv.c`: the SPIR-V rewriter for clip and cull distances.
- `bc.c`: BC formats, images and uploads.
- `VkLayer_droiddeck_mali_compat.json`: implicit layer manifest.

When it is active:
- Only in Wine processes (`WINEPREFIX` set), and only for features the GPU lacks.
- `DROIDDECK_MALI_COMPAT=1` forces it on, `0` off. `DROIDDECK_MALI_COMPAT_DISABLE=1` keeps the loader from loading it.
- Wine's own `explorer.exe` uses Zink, so it gets the layer too.
- It logs one line per device: `droiddeck-mali-compat: emulating …`.

How it ships:
- `build-apk.sh` copies `layer/` into the APK's `assets/linuxfs/usr/local/…`.
- `SessionFiles.kt` stages both files into the guest at every session start (its `optional` list).
  - Guest paths: `usr/local/lib/droiddeck-mali/` and `usr/local/share/vulkan/implicit_layer.d/`.

Not done yet:
- Unit tests for the SPIR-V rewriter. It is untested beyond DXVK's shaders, and unknown whether Silksong's shaders used clip distances at all.
- Performance: BC decoding on the CPU makes loads slow. A compute-shader decoder would be the next step.

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
- `session/SessionFiles.kt`: stages the Mali compatibility layer when the APK carries it.
- `tools/linuxfs/preload/venus.c` (new, part of `libblsession`): unsets `LIBGL_KOPPER_DISABLE` when `VN_DEBUG` has `vtest`.
  - Steam's `steamwebhelper.sh` sets it unconditionally.
  - Without kopper and without DRI3, Zink gets no GL context, and the Steam UI crash-loops.
  - Steam restores that script when it verifies its install, so it cannot be edited.

`tools/venus/mesa-venus-vtest.patch` (Mesa 26.2.4, guest side):
- No `VK_EXT_physical_device_drm` under vtest. gamescope otherwise demanded a primary node.
- Sync-fd export for fences and semaphores under vtest: a CPU wait that returns -1 (already signaled). gamescope requires `VK_KHR_external_semaphore_fd`.
- WSI skips attaching a -1 sync file to a dma-buf.
- `vn_queue_submission_init_syncs` submits only the sync slots it filled.
- Timeline semaphores free all `queue_count + 1` renderer syncs. Upstream freed one too few and leaked a vtest sync each.
- `vn_queue_submit` runs under a per-queue `submit_mutex`. The async present thread raced the app's submits; see Status.

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
   - It clones Mesa fresh and applies `tools/venus/mesa-venus-vtest.patch`. About 5 minutes.
   - To change Venus: edit `/home/delo/mali/mesa`, then refresh the patch from Git Bash:
     `MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u delo -- git -C /home/delo/mali/mesa diff > tools/venus/mesa-venus-vtest.patch`
3. Mali compatibility layer (Git Bash, Docker): `MSYS_NO_PATHCONV=1 bash tools/venus/build-layer.sh`
   - Fetches Vulkan-Headers and SPIRV-Headers (vulkan-sdk-1.4.357.0) and `bcdec.h` at a pinned commit. Under a minute.
4. Preload (Git Bash, Docker): `MSYS_NO_PATHCONV=1 bash tools/venus/build-libblsession.sh`
5. gamescope (Git Bash, Docker): `MSYS_NO_PATHCONV=1 bash tools/venus/build-gamescope.sh`
   - Emulated arm64, so it takes most of an hour.
   - Prototype 11's binary came from the same steps run by hand; the script itself has not run yet.
6. Source patch (Git Bash): `git diff 0.3.1 > ../droiddeck-mali/venus.patch`
   - Run `git add -N` on new files first.
7. APK (WSL): `bash /mnt/c/Users/derab/source/repos/DroidDeck/tools/venus/build-apk.sh <n>`
   - It packs the outputs of steps 1-5. Rebuild those first if their sources changed.

Gotchas:
- Run Docker from Git Bash, not WSL: Docker Desktop's WSL integration is off.
- Prefix Git Bash commands with `MSYS_NO_PATHCONV=1`, or paths given to `wsl`, `docker` and `adb` get mangled.
- `wsl -- bash -c '…'` loses `$VARIABLES`; put the commands in a script file and run `wsl -- bash /mnt/c/…/script.sh`.
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
- Wrap a remote `run-as ... sh -c` command in double quotes as one argument, or adb splits it. Longer scripts: push a file and run it with `run-as … sh /data/local/tmp/x.sh`.
- Session logs: `/sdcard/Download/DroidDeck/<newest>/`
  - `session.log`: gamescope, Steam and game stdout and stderr.
  - `venus.log`: the vtest and render servers.
  - `wayland.log`: the compositor; frames on screen and windows open.
  - `events.jsonl`: `frame.first` means the loading overlay lifted.
  - `crash.log`.
- Steam's own logs, live: `$A shell run-as com.droiddeck.launcher sh -c 'cd files/linuxfs/root/.local/share/Steam/logs; ...'`
  - The useful ones are `webhelper.txt`, `webhelper_gpu.txt`, `cef_log.txt`, `console_log.txt` and `gameprocess_log.txt`.
- The session script copies those logs into `<session>/steam/` only on a clean exit.
  - Clean exit: "Stop session" on the DroidDeck notification. Leaving the app only suspends the session.
- `Download/droiddeck-env` (KEY=VALUE lines) adds guest env without a rebuild. It is read at session start only.
- First Steam start downloads and unpacks about 670 MB. On later starts Steam "verifies" and re-extracts changed files.

Faster iteration on GPU code, without an APK (needs a debuggable build, see Status):
- Venus ICD: push it, then replace `files/venus/libvulkan_virtio.so` with `cp` to a new name and `mv` over it.
  - `mv` keeps the running gamescope and Steam on their old copy; overwriting in place could crash them.
- Layer: copy the two files to the guest paths above. New processes load it. The next session start restages the APK's copy.
- What the guest sees: `MSYS_NO_PATHCONV=1 bash tools/venus/guest-vulkaninfo.sh [0|1]` with a session running.

Debugging a game:
- Proton log: `PROTON_LOG=1` in `droiddeck-env`, restart the session, launch. The log is `files/linuxfs/root/steam-<appid>.log`.
  - DXVK's lines start with `info:`, `warn:`, `err:`. Proton otherwise turns DXVK logging off.
- Unity games: `Player.log` in the prefix, `pfx/drive_c/users/steamuser/AppData/LocalLow/<company>/<game>/`.
- A crash in Linux code shows in the Proton log as `handle_syscall_fault … pc=0x…`, then `Exception 0xc0000005 in Unix call`.
  1. Before the launch, run `tools/venus/watch-maps.sh '<game>.exe'` on the phone (see its header).
  2. After the crash, find the library whose range holds the pc in `cache/game-maps.txt`. Offset = pc - range start + file offset.
  3. Resolve it in WSL: `bash /mnt/c/…/tools/venus/addr2line.sh <library in droiddeck-mali> <offset>`.
  - The thread name is in the log: `Thread renamed to "dxvk-submit"`.
- Untested idea for launching a game without the user: write `steam://rungameid/<appid>` into `files/linuxfs/root/.steam/steam.pipe`.

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
12. Steam sign-in and Slay the Spire 2 at about 40 fps. Silksong: "d3d11: failed to create factory"; DXVK skips the GPU for `fillModeNonSolid` → the Mali compatibility layer.
13. Silksong: D3D11 starts, black screen, then a crash in Venus's `vtest_vcmd_submit_cmd2` → Mesa: serialize queue submits against the async present thread. Silksong plays at 40+ fps.

## Next steps

1. Silksong: check BC textures look right and loading time is bearable.
2. Test more DXVK games on different engines (Unreal, older D3D9). Fix shared gaps in the layer, never per game.
3. Direct3D 12 games use VKD3D-Proton, which has its own requirement list. Check it the same way.
4. Clean up: delete `droiddeck-env` when debugging is done.

Rules from the user:
- Never enter credentials for the user. They type the password and handle Steam Guard themselves.
- Test every build on the phone over wireless debugging.
- Fixes go in shared layers (Venus, the compatibility layer), not per game.
