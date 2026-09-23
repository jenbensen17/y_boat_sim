# sim_scratch Setup Log

Scratch environment for RoboBoat Step 1a — proving Gazebo Harmonic GUI rendering
(NVIDIA GPU, Wayland/XWayland host) and standalone ArduPilot SITL (Rover) build/run,
entirely outside `~/y_boat/y_boat_core`.

Host facts from Step 0: Omarchy (Arch, Hyprland/Wayland), XWayland + xhost installed,
RTX 4060, `nvidia-container-toolkit` confirmed working. Host UID/GID: 1000/1000, user `jenbensen`.

---

## Log

### Attempt 1 — `docker build -f Dockerfile.sim -t y_boat_sim_scratch:latest .`
Base image pull succeeded (`osrf/ros:jazzy-desktop-full`, ~1GB of layers), apt install of
`ros-jazzy-ros-gz`, `mesa-utils`, `sudo`, `git`, `python3-pip` succeeded. Failed at the
user-creation step:

```
[ 3/10] RUN groupadd --gid 1000 simuser && useradd --uid 1000 --gid 1000 -m -s /bin/bash simuser ...
groupadd: GID '1000' already exists
ERROR: process ... did not complete successfully: exit code: 4
```

**Cause:** confirmed via `docker run --rm osrf/ros:jazzy-desktop-full bash -c 'getent group 1000; getent passwd 1000'`
→ the base image already ships a user/group `ubuntu:1000:1000`. Since the host user
(`jenbensen`) is also UID/GID 1000/1000, `groupadd`/`useradd` collided with the
pre-existing `ubuntu` account rather than a real UID/GID mismatch.

**Fix:** instead of creating a new user, rename the existing `ubuntu` account/group to
`simuser` in place (keeps UID/GID 1000/1000 so host-mounted file ownership still matches):
```dockerfile
RUN usermod -l ${USERNAME} -m -d /home/${USERNAME} -s /bin/bash ubuntu \
    && groupmod -n ${USERNAME} ubuntu \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}
```
Updated `Dockerfile.sim` accordingly and rebuilt.

### Attempt 2 — rebuild after user-creation fix
User rename step succeeded this time. Build time: ~3m0s up to the failure point below
(mostly base-layer cache hits + apt installs; ArduPilot clone hadn't started timing
separately). Failed inside ArduPilot's prereqs script:

```
[ 7/10] RUN Tools/environment_install/install-prereqs-ubuntu.sh -y
...
+ sudo usermod -a -G dialout
Usage: usermod [options] LOGIN
...
ERROR: process "/bin/sh -c Tools/environment_install/install-prereqs-ubuntu.sh -y" did not complete successfully: exit code: 2
```

**Cause:** the script runs `sudo usermod -a -G dialout $USER`. Docker's `USER` instruction
selects which account runs later `RUN` steps but does **not** populate the `$USER`
environment variable in the shell — so `$USER` was empty and `usermod` got no LOGIN
argument.

**Fix:** add `ENV USER=${USERNAME}` right after the `USER ${USERNAME}` instruction so
`$USER` is set correctly for `install-prereqs-ubuntu.sh` (and anything else in the image
that assumes it).

### Attempt 3 — rebuild after $USER fix: SUCCESS
Full build succeeded end to end. Total time: 15m12s. Slowest single step: `pip3 install
wxpython` inside `install-prereqs-ubuntu.sh` had to compile from source (no matching
prebuilt wheel for this Python/Ubuntu combo) — that one `RUN` step alone took ~6m9s of
the total. ArduPilot Rover SITL build (`./waf configure --board sitl && ./waf rover`)
compiled 1379 files and linked `bin/ardurover` in 1m4.9s.

Final image: `y_boat_sim_scratch:latest`, disk usage 14.4GB, content size 4.14GB.

(Note: the harness's background-task tracker reported this run as "exit code -1" even
though the build log clearly shows `BUILD_EXIT_CODE=0` and the image was tagged
successfully — treated as a tracker-side glitch, not a real build failure, and confirmed
by `docker images` showing the tag present.)

### Rendering check — first attempt used llvmpipe, not the GPU
Ran (with user approval for `xhost +local:docker`):
```
docker run --rm --gpus all -e NVIDIA_DRIVER_CAPABILITIES=all --network host \
    -e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix y_boat_sim_scratch:latest \
    bash -lc 'glxinfo -B | grep -iE "renderer|vendor|version"'
```
Result: `OpenGL renderer string: llvmpipe (LLVM 20.1.2, 256 bits)` — software rendering,
not the GPU.

**Debug:** `nvidia-smi` *did* work inside the container (RTX 4060 visible, driver
610.57.04), and `libGLX_nvidia.so.0` was present under
`/usr/lib/x86_64-linux-gnu/`, but no NVIDIA EGL/GLX vendor file was being selected —
GLX vendor auto-detection was picking Mesa instead of NVIDIA. This is the classic
hybrid-laptop-GPU symptom the task anticipated.

**Fix:** add `__GLX_VENDOR_LIBRARY_NAME=nvidia` and `__NV_PRIME_RENDER_OFFLOAD=1` to
force GLX to use the NVIDIA vendor library. Retested with those two vars set:
```
OpenGL vendor string: NVIDIA Corporation
OpenGL renderer string: NVIDIA GeForce RTX 4060 Laptop GPU/PCIe/SSE2
OpenGL core profile version string: 4.6.0 NVIDIA 610.57.04
```
Confirmed GPU rendering. Added both env vars (plus `QT_QPA_PLATFORM=xcb`, needed for
Gazebo's Qt-based GUI under XWayland) to `run_sim_scratch.sh` permanently.

### `gz sim shapes.sdf` — no window appeared (first attempt)
With GPU rendering confirmed, `gz sim shapes.sdf` still produced **no visible window**.
Diagnostics run before guessing at a fix:

- `docker exec ... ps aux` → `gz sim server` and `gz sim gui` both alive, ~0:01 CPU each
  over 2+ minutes (idle, not crash-looping), `State: S (sleeping)`, `wchan: futex_do_wait`.
- `hyprctl clients` → **no** Gazebo window, and zero `xwayland: 1` clients at all.
- `/proc/26/environ` → `DISPLAY=:0`, `QT_QPA_PLATFORM=xcb`, `__GLX_VENDOR_LIBRARY_NAME=nvidia`
  all correctly set inside the process.
- `pgrep -a Xwayland` → `1517 Xwayland :0 -rootless ...` (XWayland IS running).
- `/tmp/.X11-unix/` → `X0` socket present, owned by `jenbensen`.

Re-ran with `gz sim -v 4` + `QT_DEBUG_PLUGINS=1`, which surfaced the actual cause:

```
[Wrn] [Gui.cc:283] Waited for 10s for a subscriber to [/gazebo/starting_world] and got none.
...
[GUI] [Dbg] [Gui.cc:355] GUI requesting list of world names. The server may be busy downloading resources. Please be patient.
```

**Cause:** not a rendering/X11 problem at all. The Qt xcb plugin loaded fine
(`loaded library ".../libqxcb.so"`, `Create main window`). The real failure was
**Gazebo Transport discovery**: `gz sim` runs the server and GUI as two separate
processes that find each other over Gazebo Transport, and under `--network host` they
never discovered each other — so the GUI had no world to render and never mapped a window.

**Fix:** `GZ_IP=127.0.0.1` (forces Gazebo Transport onto loopback). This matches
previously-known behavior for this machine's ROS 2 / Gazebo GUI setup. Retested:

```
[Msg] Received world [shapes.sdf] from the GUI.
[Msg] Gazebo Sim Server v8.11.0
[Msg] Loading SDF world file[.../shapes.sdf].
[GUI] [Msg] Added plugin [3D View] to main window
[GUI] [Msg] Loaded plugin [MinimalScene] ...
[GUI] [Msg] Added plugin [Scene Manager] to main window
```

Window confirmed present by the compositor:
```
class: Gazebo GUI
title: Gazebo Sim
xwayland: 1
mapped: 1
```
User visually confirmed the box/sphere/cylinder render correctly in the 3D view.

**GPU use confirmed while running** (this is the strongest evidence, better than glxinfo):
```
|    0   N/A  N/A          732777      G   gz sim gui                              259MiB |
```
GPU utilization 21%, 352MiB total in use — the GUI is genuinely rendering on the RTX 4060.

`GZ_IP=127.0.0.1` added to `run_sim_scratch.sh`.

### ArduPilot SITL — first attempt hung at "Waiting for heartbeat"
Launched `sim_vehicle.py -v Rover --console --map --no-rebuild`, driving MAVProxy through a
FIFO (`mkfifo /tmp/mavcmd`, with `sleep infinity > /tmp/mavcmd &` holding the write end open
so MAVProxy doesn't see EOF between commands).

Symptom: MAVProxy stuck on `Waiting for heartbeat from tcp:127.0.0.1:5760`, then `link 1 down`.

Diagnostics:
- `ps aux` → `ardurover` was alive and burning CPU; MAVProxy alive (3 procs: main + map + console).
- `ss -ltnp` → `LISTEN 1 5 0.0.0.0:5760 users:(("ardurover",...))` — note **Recv-Q = 1**, i.e. a
  connection was pending in the backlog and never being accepted.
- `ardurover`'s own stdout was invisible because `sim_vehicle.py` runs it inside an
  `xterm -iconic -hold` when `DISPLAY` is set, so its output went to that xterm's pty.

**Fix for diagnosability:** re-ran with `unset DISPLAY`, which makes `sim_vehicle.py` skip
xterm and log the vehicle binary to `/tmp/Rover.log` ("RiTW: Window access not found,
logging to /tmp/Rover.log"). That immediately revealed the real error:

```
bind port 5760 for SERIAL0
bind failed on port 5760 - Address already in use
```

**Actual cause:** a stale `ardurover` from the first attempt was still holding port 5760.
`pkill -f ardurover` had not killed it. Because the containers use `--network host`, that
stale process occupied the *host's* port 5760, so every subsequent SITL start collided
with it.

**Fix:** stop the container entirely (cleanest way to reap all stragglers) and verify
`ss -ltnp | grep 576` shows the ports free before relaunching. Lesson for later steps:
always confirm 5760/5762/5763 are free before starting SITL, since `--network host` makes
these host-global.

### ArduPilot SITL — working run
After a clean container + free ports, headless run succeeded:

```
AP: ArduRover V4.8.0-dev (b5fbe265)
Received 1272 parameters (ftp)
AP: Barometer 1 calibration complete
AP: Beginning INS calibration. Do not move vehicle
AP: ArduPilot Ready
AP: EKF3 IMU0 initialised / EKF3 IMU1 initialised
AP: EKF3 IMU0 tilt alignment complete
AP: EKF3 IMU0 MAG0 initial yaw alignment complete
AP: AHRS: EKF3 active
AP: GPS 1: probing for u-blox at 230400 baud
AP: GPS 1: detected u-blox
AP: Set HOME to -35.36326 149.1652 at 584.00m
AP: EKF3 IMU0 origin set / EKF3 IMU1 origin set
AP: EKF3 IMU0 is using GPS / EKF3 IMU1 is using GPS
```

Commands sent through the FIFO (`echo "mode GUIDED" > /tmp/mavcmd`, then `echo "arm throttle"`):
```
MANUAL> Got COMMAND_ACK: DO_SET_MODE: ACCEPTED
GUIDED> Mode GUIDED
GUIDED> Got COMMAND_ACK: COMPONENT_ARM_DISARM: ACCEPTED
AP: Throttle armed
ARMED
Arming checks disabled
```
Armed on the **first try with plain `arm throttle`** — `arm throttle force` was **not** needed.
Note the trailing `Arming checks disabled` line: SITL's default rover params leave arming
checks off, so this arm did not exercise full pre-arm validation (flagged as an open question).

**MAVLink ports** (from `/tmp/Rover.log` + host `ss -ltnp`):
- TCP **5760** — SERIAL0, primary MAVLink (what MAVProxy attaches to as `--master`)
- TCP **5762** — SERIAL1
- TCP **5763** — SERIAL2
- UDP **14550** — MAVProxy `--out` (MAVProxy-side output, not an `ardurover` listener)
- SITL RC/physics input: `--sitl 127.0.0.1:5501`, Irlock port 9005

All three TCP ports bind to `0.0.0.0`, and with `--network host` they are exposed on the
host's interfaces — worth tightening before this ever runs on a shared network.

### SITL GUI (console + map)
Relaunched with `DISPLAY` set and `--console --map`. User visually confirmed the MAVProxy
console and map windows appeared. Non-fatal noise seen on the GUI path (does not block):
```
xterm: cannot load font "10x20"
Gtk-CRITICAL **: gtk_distribute_natural_allocation: assertion 'extra_space >= 0' failed
UserWarning: Unable to import Axes3D. ... the 3D projection is not available.
Failed to download /SRTM3/filelist_python : 'utf-8' codec can't decode byte 0x80 ...
```
The SRTM one means the map module could not fetch terrain elevation tiles.

---

# Step 1b — BlueBoat in Gazebo via ArduPilot Gazebo plugin

## run_sim_scratch.sh rework (Task 0)
Rewritten with:
- `xhost +SI:localuser:$(id -un)` as the default (`XHOST_MODE=si`), with
  `XHOST_MODE=fallback` selecting `xhost +local:`. The script prints which mode/entry it
  used and how to retry with the fallback.
- **Important safety detail:** the desktop session already grants `SI:localuser:jenbensen`
  (observed in Step 1a's `xhost` output). The script therefore checks whether the entry
  already exists and only revokes on exit what *it* added — otherwise the EXIT trap would
  strip the user's own X access for unrelated apps.
- `trap cleanup EXIT INT TERM` doing that conditional revoke.
- `--init` on `docker run` so orphaned children get reaped (directly relevant after the
  Step 1a stale-`ardurover` incident).
- A pre-launch `check_ports` covering 5760-5763 plus the ArduPilot↔Gazebo JSON ports
  9002/9003, printing the owning process via `ss -ltnp`/`ss -lunp`.
- The four display/transport vars are now overridable: `GLX_VENDOR` (nvidia),
  `NV_PRIME` (1), `QT_PLATFORM` (xcb), `GZ_IP_ADDR` (127.0.0.1), plus `IMAGE`.

Verified the port check both ways: reports "5760-5763 and 9002/9003 are free" when idle,
and with a deliberate listener bound to 5760:
```
[ports] WARNING: port 5760 is already in use:
          LISTEN 0      1          127.0.0.1:5760       0.0.0.0:*    users:(("python3",pid=916186,fd=3))
```

## ArduPilot Gazebo plugin build (Task 1)

**Key deviation from the upstream instructions, required on this image.**
`ardupilot_gazebo`'s README says to `apt install libgz-sim8-dev`. That package does not
exist here — `apt-cache policy libgz-sim8-dev` returns nothing, because the OSRF apt repo
is not configured. Gazebo Harmonic in this image comes from the ROS 2 Jazzy **vendor**
packages instead:
```
ros-jazzy-gz-sim-vendor 0.0.10-1noble...
/opt/ros/jazzy/opt/gz_sim_vendor/lib/cmake/gz-sim8/gz-sim8-config.cmake
```
So the plugin is built with `source /opt/ros/jazzy/setup.bash` first, which puts the
vendored gz-sim8 cmake configs on `CMAKE_PREFIX_PATH`. Deliberately did **not** add the
OSRF repo / standalone `gz-harmonic`, to avoid two competing Harmonic installs in one image.

Deps installed via apt (the rest of the documented list is available normally):
`rapidjson-dev`, `libopencv-dev`, `libgstreamer1.0-dev`,
`libgstreamer-plugins-base1.0-dev`, `gstreamer1.0-plugins-{base,good,bad,ugly}`,
`gstreamer1.0-libav`, `gstreamer1.0-gl`.

**Result: built cleanly on the first try**, no source changes needed:
```
[100%] Linking CXX shared library libArduPilotPlugin.so
[100%] Built target ArduPilotPlugin
[ 80%] Built target CameraZoomPlugin
[ 80%] Built target ParachutePlugin
[ 90%] Built target GstCameraPlugin
```
Compile took ~13s; the whole incremental image build was 43s.

Env set in the image:
```
ENV GZ_VERSION=harmonic
ENV GZ_SIM_SYSTEM_PLUGIN_PATH=/home/simuser/ardupilot_gazebo/build
ENV GZ_SIM_RESOURCE_PATH=/home/simuser/ardupilot_gazebo/models:/home/simuser/ardupilot_gazebo/worlds
```

**ArduCopter added to the waf build.** The plugin ships no rover example world (its worlds
are `iris_runway.sdf`, `iris_warehouse.sdf`, `gimbal.sdf`, `zephyr_runway.sdf`,
`zephyr_parachute.sdf`), and its documented sanity check is
`gz sim -v4 -r iris_runway.sdf` + `sim_vehicle.py -v ArduCopter -f gazebo-iris --model JSON`.
So `./waf rover` became `./waf rover copter` — building the copter binary in the Dockerfile
rather than letting `sim_vehicle.py` compile it at runtime (which would violate the
"all installs go in Dockerfile.sim" rule). Rebuild with both targets: 2m12s.

### Plugin sanity check: `iris_runway.sdf` + gazebo-iris SITL — PASSED

Gazebo side loaded the plugin:
```
[Dbg] [SystemManager.cc:80] Loaded system [ArduPilotPlugin] for entity [15]
[Dbg] [ArduPilotPlugin.cc:1168] Computed IMU topic to be: world/iris_runway/model/iris_with_gimbal/model/iris_with_standoffs/link/imu_link/sensor/imu_sensor/imu
[Wrn] [ArduPilotPlugin.cc:1599] ArduPilot controller has reset
```
SITL side confirmed the JSON link: `JSON control interface set to 127.0.0.1:9002`.

Two problems hit on the way, both worth remembering:

**(a) `PreArm: Motors: Check frame class and type`.** `Tools/autotest/default_params/gazebo-iris.parm`
does exist and sets `FRAME_CLASS 1` / `FRAME_TYPE 1`, but those are pushed into the EEPROM
*after* boot and `FRAME_CLASS` only takes effect on the next boot.
*First fix attempted (wrong):* kill and relaunch `sim_vehicle.py` — this reproduced the Step 1a
port collision (`bind failed on port 5760 - Address already in use`, `link 1 down`, Recv-Q=1),
because the old `arducopter` keeps host-global ports under `--network host`.
*Correct fix:* reboot the autopilot **in place** from MAVProxy (`reboot` through the FIFO)
instead of restarting the process. Same process keeps the ports, params take effect, no
collision. This is the technique to use whenever a param needs a reboot.

**(b) Misread the Gazebo pose and nearly concluded the vehicle wasn't moving.**
`/world/iris_runway/pose/info` reported `iris_with_standoffs` at `z ≈ 1e-13` after a takeoff
to 10 m. That model is **nested inside** the top-level `iris_with_gimbal` model (visible in the
plugin's IMU topic path above), so its reported pose is relative to its parent and is correctly
~0. Reading the top-level model instead:
```
name: "iris_with_gimbal"   position { x: 0.0041  y: 0.0044  z: 10.1902 }   # sample 1
name: "iris_with_gimbal"   position { x: -0.0035 y: 0.0048  z: 10.1904 }   # sample 2, 3s later
```
Commanded 10 m, actual 10.19 m, stable in x/y across samples → SITL is genuinely driving
Gazebo physics. **Sanity check passed.** Lesson: always confirm which entity is the top-level
model before judging whether something moved.

## asv_wave_sim against Harmonic (Task 2)

asv_wave_sim's README advertises Garden ("or later") with CI on Jammy/gz-sim 7.1.0, so
Harmonic was the open question. Its `gz-waves/CMakeLists.txt` *does* have explicit
Harmonic branches (gz-rendering8 / gz-sim8 / sdformat14, selected by `GZ_VERSION`), so the
version support is real.

**Build failure #1 — `GzOGRE2::GzOGRE2` target not found**
```
CMake Error at src/systems/CMakeLists.txt:53 (target_link_libraries):
  Target "gz-waves1-dynamic-geometry-system" links to:
    GzOGRE2::GzOGRE2
  but the target was not found.
CMake Error at src/systems/waves/CMakeLists.txt:57 (target_link_libraries):
  Target "gz-waves1-rendering-ogre2" links to:
    GzOGRE2::GzOGRE2
```
Diagnosis: `gz-waves/CMakeLists.txt:207` calls `gz_find_package(GzOGRE2 VERSION 2.3 ...)`,
and gz-cmake's `FindGzOGRE2.cmake` resolves OGRE-Next through **pkg-config**. Everything
needed was present in the image (`FindGzOGRE2.cmake` under
`gz_cmake_vendor/share/cmake/gz-cmake3/cmake3/`, and `OGRE-Next.pc` under
`gz_ogre_next_vendor/lib/pkgconfig/`), but `PKG_CONFIG_PATH` was **empty** after sourcing
the ROS setup, so the find silently failed while the systems still referenced the target.
Verified directly:
```
pkg-config --exists OGRE-Next            -> NOT FOUND (default)
PKG_CONFIG_PATH=/opt/ros/jazzy/opt/gz_ogre_next_vendor/lib/pkgconfig pkg-config --modversion OGRE-Next
                                         -> 2.3.3
```
**Fix:** `ENV PKG_CONFIG_PATH=/opt/ros/jazzy/opt/gz_ogre_next_vendor/lib/pkgconfig`.
Result: `Finished <<< gz-waves1 [1min 1s]`, 1 package finished. **No fallback
hydrodynamics needed** — asv_wave_sim builds against Harmonic.

**Build failure #2 — plugins found but won't load**
```
Error while loading the library [.../libgz-waves1-waves-model-system.so]:
  libgz-waves1.so.1: cannot open shared object file: No such file or directory
[Err] [SystemLoader.cc:107] Failed to load system plugin: (Reason: No plugins detected in library)
```
The colcon merge-install libs weren't on the loader path (the README's
`source ~/gz_ws/install/setup.bash` step). **Fix:**
`ENV LD_LIBRARY_PATH=/home/simuser/gz_ws/install/lib:${LD_LIBRARY_PATH}`.
After that all five load cleanly: `ArduPilotPlugin`, `Hydrodynamics`, `Thruster`,
`WavesModel`, `WavesVisual`.

## BlueBoat world

No ready-made BlueBoat world exists (SITL_Models ships `catamaran_waves.sdf`, but that
depends on `asv_sim2` anemometer/wind plugins — a *different* package, for sailing).
Per BlueBoat.md the base is asv_wave_sim's `waves.sdf`, so `blueboat_waves.sdf` was derived
from it with three additions ArduPilot needs and stock `waves.sdf` lacks:
1. `gz-sim-navsat-system` — without it there is no GPS at all.
2. `<spherical_coordinates>` — geodetic origin; **must match** `--custom-location` or
   Gazebo and SITL disagree about where the boat is. Set to Utah Lake State Park,
   Provo UT (40.2386, -111.7353, 1368 m) instead of the default CMAC/Canberra.
3. `model://blueboat` include.

**Waves disabled at the user's request.** The wave field is driven by `<wind_speed>` and
`<steepness>` in *both* the WavesModel and WavesVisual plugin blocks. SDF `<include>`
offers no way to override a nested plugin's params, so the waves model is **inlined** into
the world with `wind_speed 0.0` / `steepness 0`, with mesh/texture URIs rewritten to
`model://waves/materials/...` so they still resolve upstream. The file documents how to
restore waves. One non-fatal error results from inlining without the macOS metal shader
block: `[Err] [WavesVisual.cc:399] Unable to load shader param system. Missing <shader> SDF
element.` — physics and rendering are unaffected.

Flotation, with waves on: z = -0.067 / +0.357 / +0.085 (bobbing).
Flotation, calm: z = 0.136 / 0.142 / 0.139 / 0.141 → steady waterline, ±0.005 m.

## Arming checks — `ARMING_CHECK` does not exist in 4.8.0-dev

Setting it fails outright: `Unable to find parameter 'ARMING_CHECK'`. Confirmed against the
source — `AP_Arming.cpp`'s param table has only ACCTHRESH, MIS_ITEMS, OPTIONS, MAGTHRESH,
CRSDP_IGN, NEED_LOC, **SKIPCHK**:
```
AP_GROUPINFO("SKIPCHK", 13, AP_Arming, checks_to_skip, 0),
// @DisplayName: Arm Checks to Skip (bitmask)
```
So the semantics are **inverted**: `ARMING_SKIPCHK` is a bitmask of checks to *skip*, and
its default `0` already means every pre-arm check is enabled. `blueboat.parm` now sets
`ARMING_SKIPCHK 0` explicitly.

**This corrects a Step 1a conclusion.** Step 1a recorded "SITL's default rover params leave
arming checks off" based on MAVProxy printing `Arming checks disabled`. That string does
**not** exist anywhere in the ArduPilot source — it is MAVProxy's own output when it cannot
find the legacy `ARMING_CHECK` parameter. Checks were never actually disabled.

Result with `ARMING_SKIPCHK 0` (all checks active): **arms successfully** —
`COMMAND_ACK: COMPONENT_ARM_DISARM: ACCEPTED`, `Throttle armed`, `ARMED`. A transient
`PreArm: Accels inconsistent` appears during startup while the hull is still settling; it
clears and does not block arming.

## launch_blueboat.sh — MAVProxy is load-bearing

Two failures worth recording, both with the same root cause:

**(a) `set -u` vs ROS.** `source /opt/ros/jazzy/setup.bash` under `set -u` dies instantly
with `AMENT_TRACE_SETUP_FILES: unbound variable`. Fixed by wrapping the source in
`set +u` / `set -u`.

**(b) SITL starts then immediately dies.** Symptom (visible as GUI windows flashing open
and closing):
```
SIM_VEHICLE: MAVProxy exited
SIM_VEHICLE: Killing tasks
...
Closed connection on SERIAL0
```
MAVProxy's interactive console reads stdin. Under `docker exec -d` (or cron/CI) there is no
stdin, so it gets immediate EOF, exits cleanly — and `sim_vehicle.py` then tears down the
vehicle binary too. **Fix:** the HEADLESS path passes `--mavproxy-args="--daemon"`, which
runs MAVProxy with no console so it survives having no stdin.

Corollary confirmed by experiment: `pkill -f mavproxy.py` also kills `ardurover`. For the
MAVROS step, where MAVROS is the GCS, use `sim_vehicle.py --no-mavproxy` rather than trying
to kill MAVProxy afterwards.

**Known bug (not yet fixed):** `launch_blueboat.sh`'s pre-flight port check uses `ss`, which
is **not installed in the container**, so the check silently never fires there. It does work
when the script is run on a host that has `ss`. Should be switched to parsing
`/proc/net/tcp` or using `python3 -c`.

## Driving results

Tests driven by `drive_test.py` over MAVLink (pymavlink) on **SERIAL1 / tcp:5762**, chosen so
it does not disturb MAVProxy on SERIAL0 / tcp:5760.

**First run produced two invalid results, both caught and fixed:**
- AUTO reported `now heading to waypoint 4` at t=1s, `final waypoint reached`, and
  `cross-track error: mean=0.16 m max=0.16 m samples=1`. This was a **false pass** — the
  mission counter was still at the end of a previous run, so AUTO "completed" instantly.
  Fixed with `mission_set_current_send(..., 1)` before switching to AUTO, plus a minimum
  run time before accepting the final waypoint.
- MANUAL reported 0.3 m of travel. Fixed the override rate (10 Hz) — but see below, this
  turned out to be a harness limitation rather than a sim problem.

**MANUAL** — verified, but *not* by `drive_test.py`.
Via MAVProxy (`rc 3 1900`): boat moved from (-0.59, 0.31) to (-12.67, 9.37) in Gazebo,
≈15.2 m in 12 s (~1.3 m/s). Visible in the GUI.
Via `drive_test.py` RC override on a second link: only 0.1–0.3 m. Diagnosed — the override
never reaches the autopilot, `chan3_raw` stays at 1500 despite 10 Hz
`RC_CHANNELS_OVERRIDE` at 1900, because MAVProxy on SERIAL0 is simultaneously sending its
own RC values and wins. Attempting to settle it by killing MAVProxy instead killed SITL
(see above), so the MAVProxy-based result stands as the MANUAL evidence.
(`SYSID_MYGCS` also returns NOT FOUND in this build — another renamed parameter, not
investigated further.)

**AUTO mission** — 4 waypoints, ~25 m square, genuinely executed:
```
[auto] starting at waypoint 4      <- stale counter, rewound before AUTO
[auto] t=    0s  now heading to waypoint 1
[auto] t=   25s  now heading to waypoint 2
[auto] t=   99s  now heading to waypoint 3
[auto] t=  124s  now heading to waypoint 4
[auto] cross-track error: mean=12.62 m  max=25.04 m  samples=111
```
**Cross-track behaviour: poor — overshooting, not smooth.** Mean cross-track error of
12.6 m on 25 m legs is comparable to the leg length itself, and max 25 m means the boat
strayed a full leg-length off track. The leg timings say the same thing: waypoint 1→2 took
25 s but 2→3 took 74 s, consistent with overshooting a corner and having to come back.
This is a tuning problem (turn rate / `WP_RADIUS` / `CRUISE_SPEED` / skid-steer gains), not
a plumbing problem — the boat does complete the mission.

**GUIDED** — works. Single position target ~50 m north of home, reached on both runs:
`ARRIVED within 5.0 m` and `ARRIVED within 4.5 m`. Distance-to-target was non-monotonic on
the first run (12.1 → 25.3 → 13.9 → 5.6 m), again consistent with overshoot.

---

# Step 1c+3 — pinned versions, ROS 2 bridge, MAVROS control

## Version pinning

Pinned via Dockerfile ARGs. The three non-ArduPilot SHAs were read back **out of the
Step 1b image** (`git -C <repo> rev-parse HEAD`) before rebuilding, so the pin reproduces
exactly what Step 1b was validated against rather than whatever master happens to be:

| component | pin | note |
|---|---|---|
| ArduPilot | `Rover-4.7.1` (`dbe79216`) | was unpinned master `b5fbe265` (4.8.0-dev) |
| ardupilot_gazebo | `082a0fe231f6e63bc8d1598f1cba461d9e2ea7f5` | as tested in 1b |
| asv_wave_sim | `ca8629df4e191235753dfae92ef725d30b923364` | as tested in 1b |
| SITL_Models | `25bc38ed8c6c0345840159a8cbc0b02781d52f3c` | as tested in 1b |

Stable Rover tags available: 4.7.1 (latest), 4.7.0, 4.6.3, 4.6.2, 4.6.1, 4.6.0, 4.5.x.
Chose **Rover-4.7.1**.

**`git describe` is misleading here.** In the built image it reports `APMrover2-beta`, not
`Rover-4.7.1`. Cause: 4.7.1 was a synchronised release and ~20 tags point at the same
commit (`Copter-4.7.1`, `Plane-4.7.1`, `APMrover2-stable`, …), so `describe` picks one
alphabetically. Verified the pin properly instead:
```
git rev-parse HEAD            -> dbe792162d06cab66c3475fd5556bf7a120f119e
git ls-remote ... Rover-4.7.1 -> dbe792162d06cab66c3475fd5556bf7a120f119e   # match
Rover/version.h               -> #define THISFIRMWARE "ArduRover V4.7.1"
```
and at runtime SITL prints `AP: ArduRover V4.7.1 (dbe79216)`.

Also added `iproute2`, which fixes the Step 1b Problem 9 (`launch_blueboat.sh`'s `ss`
port check silently never fired inside the container). The script now also degrades
gracefully with a warning if `ss` is ever missing again.

Build: **16m52s**, exit 0. Tagged `y_boat_sim_scratch:1c` rather than overwriting
`:latest`, so the known-good Step 1b image survives if the pin regresses anything.

## Parameter revalidation against Rover-4.7.1

Pulled all 1256 FCU params through MAVROS and read each one back:

| param | value on 4.7.1 | verdict |
|---|---|---|
| `CRUISE_SPEED` | 2.0 | OK |
| `CRUISE_THROTTLE` | 50 | OK |
| `FRAME_CLASS` | 2 | OK (boat) |
| `WP_SPEED` | 2.0 | OK |
| `ARMING_SKIPCHK` | 0 | OK — all pre-arm checks enabled |
| `ARMING_CHECK` | *Parameter not set* | confirms it does not exist |

**No fixes were needed.** Notably the `ARMING_CHECK` → `ARMING_SKIPCHK` rename found in
Step 1b on 4.8.0-dev **also holds on 4.7.1**, i.e. the rename predates 4.7.1 and is not a
master-only change. `AP_Arming.cpp` on the pinned tree lists ACCTHRESH, MIS_ITEMS,
OPTIONS, MAGTHRESH, CRSDP_IGN, NEED_LOC, SKIPCHK — no CHECK.

Revalidated behaviour on the pinned build: boat floats (z steady 0.1401 m), arms with all
checks active, and reaches a GUIDED position target (4.9 m in 16 s).

## ros_gz_bridge

`bridge.yaml` + `launch/sim_bridge.launch.py`, deliberately minimal (no sensors):
- `/clock` — GZ_TO_ROS, `gz.msgs.Clock` → `rosgraph_msgs/msg/Clock`
- `/sim/ground_truth/odom` — GZ_TO_ROS, from `/model/blueboat/odometry`. The BlueBoat model
  already carries `gz::sim::systems::OdometryPublisher` (odom_frame=odom,
  robot_base_frame=base_link, dimensions=3), so no world change was needed. Namespaced
  under `/sim/` and documented as debug-only so it can't be mistaken for MAVROS's estimate.

Both directions are GZ_TO_ROS only — nothing in ROS should drive Gazebo directly; the boat
is commanded through ArduPilot.

The bridge node deliberately does **not** set `use_sim_time`: it is the process publishing
`/clock`, so making it wait on `/clock` would be circular.

## MAVROS

Installed `ros-jazzy-mavros` + `ros-jazzy-mavros-extras` and ran
`/opt/ros/jazzy/lib/mavros/install_geographiclib_datasets.sh` in the Dockerfile (without
the geoid datasets the node aborts at startup). `egm96-5.pgm` present afterwards.

`launch/mavros_sim.launch.py` wraps MAVROS's own apm launch so its plugin lists and config
are kept, and uses `SetParameter(name="use_sim_time", value=True)` at LaunchDescription
scope to force sim time onto the included nodes — cleaner than editing MAVROS's config.

Connection verified: `/mavros/state` → `connected: true`, `mode: MANUAL`, and mode/armed
both update when changed. Measured rates:

| topic | rate |
|---|---|
| `/clock` | 939 Hz |
| `/sim/ground_truth/odom` | 46.7 Hz |
| `/mavros/local_position/odom` | 3.78 Hz |
| `/mavros/global_position/global` | 3.79 Hz |
| `/mavros/state` | 0.94 Hz |

**The MAVROS position rates are low (3.8 Hz).** That is ArduPilot's default MAVLink stream
rate, not a MAVROS fault, but it is likely too slow for Nav2 and should be raised
(`SRx_POSITION` / `/mavros/set_message_interval`) before Nav2 work.

Note the 0.94 Hz `/mavros/state`: after an arm/mode service call you must wait for the next
state message before reading it back, or you will see stale values.

## ROS-only control (no MAVProxy commands)

All of the following was done purely over ROS 2.

- `set_mode(GUIDED)` → `mode_sent=True`, state.mode becomes GUIDED
- `arming(True)` → `success=True, result=0`, state.armed becomes True
- Position setpoint on `/mavros/setpoint_position/local` → **ARRIVED within 4.9 m after 16 s**

### Body-frame velocity — the important finding

`/mavros/setpoint_velocity/cmd_vel_unstamped` is interpreted in the **local ENU** frame, so
it moves the boat in a fixed world direction — not what a Nav2 `cmd_vel` needs.

Body frame requires **`/mavros/setpoint_raw/local`** (`mavros_msgs/msg/PositionTarget`) with:
- `coordinate_frame: 8` (`FRAME_BODY_NED`)
- `type_mask: 1479` = ignore position (1|2|4) + ignore accel (64|128|256) + ignore yaw (1024),
  keeping `velocity` and `yaw_rate`
- `velocity.x` = forward speed (body), `yaw_rate` = rad/s

Tested at two headings, streaming at 10 Hz:
```
headingA  heading -0.5 deg   -> moved 18.7 m, travel dir    8.4 deg  (err  8.9 deg)
rotate ~90 deg (yaw_rate 0.4 rad/s, 8 s)
headingB  heading -111.0 deg -> moved 17.4 m, travel dir  -88.8 deg  (err 22.2 deg)
heading changed by 110.5 deg between tests
```
Travel direction follows the boat's heading in both cases → **body-frame velocity confirmed
working**. The 9-22 deg errors are consistent with the known-poor tuning from Step 1b (the
boat is still settling during the 12 s window); direction tracks heading, magnitude of the
error is a tuning artefact, not a frame problem.

### GUIDED timeout

After the last setpoint the boat held ~1.5 m/s for ~4 s, then decelerated, effectively
stopping **6.3 s** after the last setpoint.

Root cause found in source, and it is **not** a parameter — `GUID_TIMEOUT` does not exist on
Rover 4.7.1. `Rover/mode_guided.cpp` lines 55 and 79:
```c
if (have_attitude_target && (millis() - _des_att_time_ms) > 3000) {
```
i.e. a hardcoded **3000 ms** guided target timeout, after which the boat decelerates
(~3 s more to coast to a stop). **A future Nav2 → cmd_vel bridge node must republish at
well above 1/3 Hz (10 Hz used here) or the boat will stall every 3 seconds.**

## TF tree

- `/tf` — advertised by node `mavros`, but **publishes nothing**. `ros2 topic hz /tf` over
  8 s produced no messages at all.
- `/tf_static` — three static transforms, all MAVROS ENU↔NED/FRD aliases:
  `map → map_ned`, `odom → odom_ned`, `base_link → base_link_frd`

**MAVROS does not publish dynamic TF by default** — there is no `map → odom → base_link`
chain, so nothing currently provides the transform Nav2 would need. Reported only, not
redesigned, as instructed.

## Sim time

- `/mavros` → `use_sim_time: True`
- `/sim_bridge` → `use_sim_time: False` (intentional; it is the `/clock` source)

## Problems

1. **`git describe` reports `APMrover2-beta` instead of `Rover-4.7.1`** — ~20 tags share the
   commit. Resolved by verifying `rev-parse HEAD` against `git ls-remote` and reading
   `THISFIRMWARE`. Worth knowing before anyone "fixes" the pin.
2. **`/mavros/param/get` does not exist** in this MAVROS. FCU params are exposed as ROS 2
   parameters on a `/mavros/param` node instead:
   `ros2 service call /mavros/param/pull ...` then `ros2 param get /mavros/param <NAME>`.
3. **`ros2 service call` reported an invalid-context error** on a first attempt
   (`failed to check service availability: rcl node's context is invalid`) while probing a
   non-existent service; harmless once the correct interface was used.
4. **`armed: false` immediately after a successful arm call** — `/mavros/state` only
   publishes at 0.94 Hz, so the echo caught a stale message. Not a real failure.

## QGroundControl

### Pinned Linux install (in Dockerfile.sim)

Stable release candidates at time of pinning: **v5.1.4** (latest stable, chosen),
v5.1.3 (stable), v5.1.0. v5.1.2 was a release *candidate* (`prerelease: true`) and was
excluded.

```
ARG QGC_VERSION=v5.1.4
ARG QGC_SHA256=1c4ac089abfaac6c6fcd75c7b477ea18da1bc3592cddca5ab1a19c1a13410e65
```

**Upstream publishes no checksum or signature.** The v5.1.4 release assets are only
`QGroundControl-x86_64.AppImage`, `QGroundControl-aarch64.AppImage`,
`QGroundControl.dmg`, `QGroundControl.apk`, `QGroundControl-installer-AMD64.exe` and
`QGroundControl-installer-ARM64.exe` — there is no `*.sha256` / `SHA256SUMS` asset.
`QGC_SHA256` is therefore a **trust-on-first-use** pin: the hash of the exact 187 MB
artifact downloaded and tested here, checked with `sha256sum -c` during the build so the
build fails loudly if those bytes ever change.

Containers normally lack FUSE, so the AppImage is **self-extracted** with
`--appimage-extract` into `/opt/qgroundcontrol` and run via its `AppRun`, rather than
being mounted. A `/usr/local/bin/qgroundcontrol` launcher wraps that.

Extraction happens as root (it is just unsquashfs, no QGC code runs), but the launcher is
invoked as `simuser` — **QGC refuses to run as root**, and `launch_blueboat.sh` checks
`id -u` and refuses with a clear message rather than letting QGC fail on its own.

Extra runtime deps installed for the Qt6 AppImage: `libxcb-xinerama0`, `libxcb-cursor0`,
`libxkbcommon-x11-0`, `libpulse0`, `libgl1`, `wget`. (GStreamer, which QGC wants for video
streaming, is already installed by the ardupilot_gazebo step.)

### Bringup

`QGC=1 ./launch_blueboat.sh` starts QGC with the same display environment as Gazebo
(`DISPLAY` + the `/tmp/.X11-unix` mount from `run_sim_scratch.sh`, and
`QT_QPA_PLATFORM=xcb` to keep Qt off Wayland under XWayland). It is skipped with an
explanatory message when `HEADLESS=1` (no display), when the launcher is missing, or when
running as root.

### Coexistence with MAVROS — verified, no interference

```
UNCONN 0 0   0.0.0.0:14550 0.0.0.0:* users:(("QGroundControl",pid=315,fd=80))
UNCONN 0 0 127.0.0.1:14551 0.0.0.0:* users:(("mavros_node",pid=353,fd=21))
```
QGC auto-connects on **UDP 14550** (MAVProxy's GCS output) while MAVROS holds **14551**.
Both stayed connected simultaneously; the user visually confirmed QGC showing the vehicle
with live telemetry.

Checks with both attached:
- `/mavros/state` → `connected: true` throughout
- a ROS-issued `set_mode GUIDED` took effect (`mode: MANUAL` → `GUIDED`) with QGC attached
- `/mavros/local_position/odom` rate 3.60 Hz vs 3.78 Hz with MAVROS alone — within noise

**No interference observed.** This works because MAVProxy fans the same stream out to two
separate UDP endpoints, so the two GCSs never contend for a port. Caveat: they are two
independent control authorities on one vehicle — either can arm/disarm or change mode, so
whoever is driving should be agreed out-of-band.

Minor observation: `ps` shows `--out 127.0.0.1:14550` **twice**, because `sim_vehicle.py`
adds its own default 14550 output in addition to the one the script passes. Harmless
(duplicate output to the same endpoint), but it means 14550 would be live even without the
explicit `MAVLINK_OUTS` entry.

### Native install for macOS / Windows teammates (documented, NOT tested)

Same pinned version, **v5.1.4**, so everyone runs identical QGC.

**macOS** — <https://github.com/mavlink/qgroundcontrol/releases/download/v5.1.4/QGroundControl.dmg>
Open the .dmg and drag QGroundControl to Applications. On first run macOS Gatekeeper will
block an unsigned build: right-click the app → Open, or
`xattr -dr com.apple.quarantine /Applications/QGroundControl.app`.

**Windows** — <https://github.com/mavlink/qgroundcontrol/releases/download/v5.1.4/QGroundControl-installer-AMD64.exe>
(ARM64 machines: `QGroundControl-installer-ARM64.exe`.) Run the installer; SmartScreen may
warn about an unsigned publisher.

**How a native QGC connects to this sim.** The sim's MAVLink outputs go to `127.0.0.1`,
which is inside the container/VM, so a native QGC on the host needs the stream pointed at
it:

- *Linux host, same machine* — already works, since the container uses `--network host`;
  native QGC auto-connects on 14550 exactly like the in-container one.
- *macOS / Windows* — the sim will be running under Docker Desktop (a Linux VM), so
  `127.0.0.1` inside the container is **not** the host. Either:
  1. add an extra output aimed at the host, e.g. launch with
     `MAVLINK_OUTS="127.0.0.1:14550 127.0.0.1:14551 host.docker.internal:14552"`, then in
     QGC add **Application Settings → Comm Links → Add → UDP**, listening port `14552`; or
  2. run the sim in a Linux VM and point QGC at that VM's IP on 14550 the same way.

  QGC's automatic UDP discovery only listens on 14550 locally, so for the cross-VM case add
  the link manually rather than relying on auto-connect.

Neither native path was tested here — documented only, as requested.

### Bug: `mavproxy.py` not found in an interactive shell (found in real use, now fixed)

Reported by the user running the documented flow (`./run_sim_scratch.sh`, then
`./sim_scratch/launch_blueboat.sh`). Gazebo, the bridge and MAVROS all started, but SITL
died immediately:

```
SIM_VEHICLE: Run MavProxy
[Run MavProxy] An exception has occurred with command: 'mavproxy.py --retries 5 ...'
[Errno 2] No such file or directory: 'mavproxy.py'
SIM_VEHICLE: Killing tasks
```

MAVROS then sat with no flight controller, so `/mavros/local_position/odom` never appeared
and `ros_control_test.py` aborted with "no /mavros/state or /mavros/local_position/odom".

**Cause.** `install-prereqs-ubuntu.sh` installs MAVProxy into a virtualenv
(`~/venv-ardupilot/bin/mavproxy.py`) and activates it from **`~/.profile` line 28 only**:
```
/home/simuser/.profile:28:source /home/simuser/venv-ardupilot/bin/activate
```
`~/.bashrc` has no such line. So:
- `bash -lc` (login shell) sources `.profile` → venv on PATH → works. **Every test in
  Steps 1b/1c used `bash -lc`, which is why this was never caught.**
- `docker run -it ... bash` (interactive, non-login) sources `.bashrc` only → venv NOT on
  PATH → `which mavproxy.py` fails. This is the documented user-facing flow.

The Dockerfile's `ENV PATH` listed `.local/bin` and `ardupilot/Tools/autotest` but never
the venv, so it depended entirely on dotfiles.

**Fix.** Put the venv on PATH in the image, independent of shell type:
```dockerfile
ENV PATH="${PATH}:/home/${USERNAME}/venv-ardupilot/bin"
```
**Appended, not prepended, deliberately:** the venv also contains a `python3`, and putting
it ahead of `/usr/bin/python3` would shadow the interpreter that has `rclpy` and break ROS 2
nodes. `mavproxy.py` exists only in the venv so ordering does not affect finding it, and its
shebang still selects the venv interpreter.

Verified after rebuild (interactive shell):
```
which mavproxy.py -> /home/simuser/venv-ardupilot/bin/mavproxy.py
python3          -> /usr/bin/python3
python3 -c "import rclpy" -> rclpy OK
```

**Lesson:** test the flow the way it is documented for users. Using `bash -lc` throughout
hid a bug that the documented `run_sim_scratch.sh` → `launch_blueboat.sh` path hits every
time.

Related fix in the same session: `run_sim_scratch.sh` defaulted to `IMAGE=...:latest`, the
older Step 1b image with no MAVROS, so `ros2 service call ... mavros_msgs/srv/CommandBool`
failed with "The passed service type is invalid". Default is now `:1c`.
