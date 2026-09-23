# RoboBoat Step 1c+3 Report — pinned versions, ROS 2 bridge, MAVROS control

Goal: a sim teammates can use to write ROS 2 nodes and test Nav2. This step delivers stable
pinned versions, a basic ROS 2 connection, and MAVROS control of the boat.
No sensors, no tuning, no Nav2.

Work confined to `~/y_boat/sim_scratch/`. `~/y_boat/y_boat_core` untouched.

**Outcome: all tasks achieved.** The sim is pinned and reproducible, one command brings up
Gazebo + SITL + ros_gz_bridge + MAVROS, and the boat is fully controllable from ROS 2 alone
(mode, arming, position setpoints, and body-frame velocity).

QGroundControl is also installed from a pinned AppImage and runs alongside MAVROS.

Four findings matter for the Nav2 work that follows:
1. Body-frame velocity needs `setpoint_raw/local`, **not** `cmd_vel_unstamped`.
2. ArduPilot stops the boat **3 s** after the last guided setpoint — hardcoded, not a parameter.
3. **MAVROS publishes no dynamic TF**, so there is no `map → odom → base_link` chain yet.
4. A latent bug in the GUI launch path was found and fixed — bash sends background jobs'
   stdin to `/dev/null`, which had been silently killing MAVProxy's console (and with it
   SITL) since Step 1b.

## Pinned versions

All pins are Dockerfile `ARG`s. The three non-ArduPilot SHAs were read back **out of the
Step 1b image** before rebuilding, so the pin reproduces exactly what Step 1b validated
rather than whatever master happened to be that day.

| Component | Pin | Notes |
|---|---|---|
| ArduPilot | **`Rover-4.7.1`** (`dbe792162d06cab66c3475fd5556bf7a120f119e`) | was unpinned master `b5fbe265` = 4.8.0-dev |
| ardupilot_gazebo | `082a0fe231f6e63bc8d1598f1cba461d9e2ea7f5` | as tested in Step 1b |
| asv_wave_sim | `ca8629df4e191235753dfae92ef725d30b923364` | as tested in Step 1b |
| SITL_Models | `25bc38ed8c6c0345840159a8cbc0b02781d52f3c` | as tested in Step 1b |
| Base image | `osrf/ros:jazzy-desktop-full` | unchanged |

**Rover release candidates considered** (all stable tags available):
`Rover-4.7.1` ← chosen (latest stable), `Rover-4.7.0`, `Rover-4.6.3`, `Rover-4.6.2`,
`Rover-4.6.1`, `Rover-4.6.0`, `Rover-4.5.7` … `Rover-4.5.2`.
Chose 4.7.1 as the newest stable release; ArduPilot is cloned with
`--recurse-submodules --branch ${ARDUPILOT_TAG}`.

**Watch out: `git describe` lies here.** In the built image it reports `APMrover2-beta`,
not `Rover-4.7.1`, because 4.7.1 was a synchronised release and ~20 tags point at that same
commit (`Copter-4.7.1`, `Plane-4.7.1`, `APMrover2-stable`, `ArduCopter-beta`, …), so
`describe` picks one alphabetically. The pin was verified properly instead:

```
git rev-parse HEAD                    -> dbe792162d06cab66c3475fd5556bf7a120f119e
git ls-remote ... refs/tags/Rover-4.7.1 -> dbe792162d06cab66c3475fd5556bf7a120f119e   # match
Rover/version.h                       -> #define THISFIRMWARE "ArduRover V4.7.1"
runtime                               -> AP: ArduRover V4.7.1 (dbe79216)
```

Also added **`iproute2`**, which fixes Step 1b Problem 9: `launch_blueboat.sh`'s `ss` port
pre-flight check silently never fired inside the container. The check now also degrades
gracefully with a warning if `ss` is ever absent again.

Build: **16m52s**, exit 0. Tagged **`y_boat_sim_scratch:1c`** rather than overwriting
`:latest`, so the known-good Step 1b image survives if a pin regresses something.

Revalidation on the pinned build: boat floats (z steady **0.1401 m**), arms with all
pre-arm checks active, and reaches a GUIDED position target (**4.9 m in 16 s**).

## Parameter revalidation

Pulled all **1256** FCU parameters through MAVROS and read each one back:

| Parameter | Value on Rover-4.7.1 | Verdict |
|---|---|---|
| `CRUISE_SPEED` | 2.0 | OK |
| `CRUISE_THROTTLE` | 50 | OK |
| `FRAME_CLASS` | 2 | OK (boat) |
| `WP_SPEED` | 2.0 | OK |
| `ARMING_SKIPCHK` | 0 | OK — all pre-arm checks enabled |
| `ARMING_CHECK` | *Parameter not set* | confirms it does not exist |

**No fixes were needed.** The `ARMING_CHECK` → `ARMING_SKIPCHK` rename discovered in Step 1b
on 4.8.0-dev **also holds on 4.7.1**, so the rename predates 4.7.1 and is not a master-only
change. `AP_Arming.cpp` on the pinned tree lists only ACCTHRESH, MIS_ITEMS, OPTIONS,
MAGTHRESH, CRSDP_IGN, NEED_LOC, **SKIPCHK** — no CHECK.

Downgrading 4.8.0-dev → 4.7.1 changed none of the parameters we rely on.

## ROS 2 topics

146 topics total. The interesting ones plus measured rates:

| Topic | Rate | Source |
|---|---|---|
| `/clock` | **939 Hz** | ros_gz_bridge (Gazebo, 1 ms physics step) |
| `/sim/ground_truth/odom` | **46.7 Hz** | ros_gz_bridge (BlueBoat OdometryPublisher) |
| `/mavros/local_position/odom` | **3.78 Hz** | MAVROS |
| `/mavros/global_position/global` | **3.79 Hz** | MAVROS |
| `/mavros/state` | **0.94 Hz** | MAVROS |

Both odometry topics move when the boat moves (verified during the control tests — position
went from (26.9, -1.3) to (47.7, 2.2) across the velocity runs).

**Flag: the MAVROS position rates are low at 3.8 Hz.** That is ArduPilot's default MAVLink
stream rate rather than a MAVROS fault, but it is likely too slow for Nav2 and should be
raised (`SRx_POSITION`, or `/mavros/set_message_interval`) before Nav2 work starts.

Also note `/mavros/state` at 0.94 Hz: after an arm or mode service call you must wait for
the next state message before reading it back, or you will see a stale value. (This bit me
once — an `armed: false` echo immediately after a successful arm.)

Non-MAVROS topics: `/clock`, `/sim/ground_truth/odom`, `/tf`, `/tf_static`, `/diagnostics`,
`/parameter_events`, `/rosout`, `/move_base_simple/goal`, `/uas1/mavlink_sink`,
`/uas1/mavlink_source`. Everything else is under `/mavros/…`.

Nodes: `/mavros`, `/mavros_node`, `/mavros_router`, `/sim_bridge`, plus ~57 per-plugin
MAVROS nodes (`/mavros/local_position`, `/mavros/setpoint_raw`, `/mavros/param`, …).

### Bridge configuration

`bridge.yaml` — deliberately minimal, no sensors, and **GZ_TO_ROS only** (nothing in ROS
should drive Gazebo directly; the boat is commanded through ArduPilot):

```yaml
- ros_topic_name: "/clock"
  gz_topic_name: "/clock"
  ros_type_name: "rosgraph_msgs/msg/Clock"
  gz_type_name: "gz.msgs.Clock"
  direction: GZ_TO_ROS

- ros_topic_name: "/sim/ground_truth/odom"
  gz_topic_name: "/model/blueboat/odometry"
  ros_type_name: "nav_msgs/msg/Odometry"
  gz_type_name: "gz.msgs.Odometry"
  direction: GZ_TO_ROS
```

No world change was needed for ground truth: the BlueBoat model already carries
`gz::sim::systems::OdometryPublisher` (`odom_frame=odom`, `robot_base_frame=base_link`,
`dimensions=3`), publishing on the default topic `/model/blueboat/odometry`.

It is namespaced `/sim/…` and documented as **debug/evaluation only** so it cannot be
confused with MAVROS's estimate. Nav2 and team code must consume
`/mavros/local_position/odom`.

## MAVROS

Installed `ros-jazzy-mavros` + `ros-jazzy-mavros-extras` and ran
`/opt/ros/jazzy/lib/mavros/install_geographiclib_datasets.sh` in the Dockerfile — without
the geoid datasets the node aborts at startup. `egm96-5.pgm` confirmed present afterwards.

`launch/mavros_sim.launch.py` wraps MAVROS's own apm launch (keeping its plugin lists and
config) and forces sim time with `SetParameter(name="use_sim_time", value=True)` at
LaunchDescription scope, which applies to the included nodes — cleaner than editing MAVROS's
own config files.

Connection confirmed:
```
connected: true
armed: false
guided: false
manual_input: true
mode: MANUAL
```
`mode` and `armed` both update when changed (demonstrated by the ROS-only control below, and
they tracked correctly throughout).

## ROS-only control

Everything below was done purely over ROS 2 — **no MAVProxy commands**.

### Copy-pasteable commands

```bash
# --- mode + arming ---------------------------------------------------------
ros2 service call /mavros/set_mode mavros_msgs/srv/SetMode \
  "{base_mode: 0, custom_mode: 'GUIDED'}"
# -> mavros_msgs.srv.SetMode_Response(mode_sent=True)

ros2 service call /mavros/cmd/arming mavros_msgs/srv/CommandBool "{value: true}"
# -> mavros_msgs.srv.CommandBool_Response(success=True, result=0)

ros2 topic echo /mavros/state --once          # NB: only 0.94 Hz, wait for a fresh message

# --- position setpoint (local ENU) -----------------------------------------
ros2 topic pub -r 10 /mavros/setpoint_position/local geometry_msgs/msg/PoseStamped \
  "{header: {frame_id: 'map'}, pose: {position: {x: 30.0, y: 0.0, z: 0.0},
    orientation: {w: 1.0}}}"

# --- BODY-FRAME velocity: forward 1.5 m/s, no yaw rate ---------------------
# coordinate_frame 8 = FRAME_BODY_NED
# type_mask 1479 = ignore position(1|2|4) + accel(64|128|256) + yaw(1024)
#                = keep velocity + yaw_rate
ros2 topic pub -r 10 /mavros/setpoint_raw/local mavros_msgs/msg/PositionTarget \
  "{coordinate_frame: 8, type_mask: 1479,
    velocity: {x: 1.5, y: 0.0, z: 0.0}, yaw_rate: 0.0}"

# --- turn in place: yaw rate only ------------------------------------------
ros2 topic pub -r 10 /mavros/setpoint_raw/local mavros_msgs/msg/PositionTarget \
  "{coordinate_frame: 8, type_mask: 1479,
    velocity: {x: 0.0, y: 0.0, z: 0.0}, yaw_rate: 0.4}"

# --- disarm ----------------------------------------------------------------
ros2 service call /mavros/cmd/arming mavros_msgs/srv/CommandBool "{value: false}"

# --- reading FCU params (see Problems: there is no /mavros/param/get) ------
ros2 service call /mavros/param/pull mavros_msgs/srv/ParamPull "{force_pull: true}"
ros2 param get /mavros/param FRAME_CLASS
```

`ros_control_test.py` in the scratch dir automates all of the above with measurements.

### Results

| Test | Result |
|---|---|
| `set_mode(GUIDED)` | `mode_sent=True`, `state.mode` → GUIDED |
| `arming(true)` | `success=True, result=0`, `state.armed` → True |
| Position setpoint | **ARRIVED within 4.9 m after 16 s** |
| Body-frame velocity | **PASS at two headings** (below) |
| GUIDED timeout | **3 s hardcoded**, boat fully stopped 6.3 s after last setpoint |

### Body-frame velocity — what actually works

This is the finding that matters for the future Nav2 → `cmd_vel` bridge node.

**`/mavros/setpoint_velocity/cmd_vel_unstamped` is interpreted in the local ENU frame** —
it drives the boat in a fixed world direction, which is *not* what a Nav2 `cmd_vel` means.

Body frame requires **`/mavros/setpoint_raw/local`** with `mavros_msgs/msg/PositionTarget`:

| Field | Value | Meaning |
|---|---|---|
| `coordinate_frame` | `8` | `FRAME_BODY_NED` |
| `type_mask` | `1479` | ignore position (1\|2\|4) + accel (64\|128\|256) + yaw (1024); keep velocity + yaw_rate |
| `velocity.x` | forward speed (m/s) | body-frame forward |
| `yaw_rate` | rad/s | turn rate |

Streamed at 10 Hz, tested at two headings ~110° apart:

```
headingA  heading   -0.5 deg  -> moved 18.7 m, travel dir    8.4 deg  (err  8.9 deg)
rotate ~90 deg (yaw_rate 0.4 rad/s for 8 s)
headingB  heading -111.0 deg  -> moved 17.4 m, travel dir  -88.8 deg  (err 22.2 deg)
heading changed by 110.5 deg between tests
```

Travel direction followed the boat's own heading in both cases → **body-frame velocity
confirmed working**. The 9–22° errors are consistent with the known-poor tuning carried over
from Step 1b (the boat is still settling during the 12 s window); the *direction* tracks
heading, and the error magnitude is a tuning artefact, not a frame problem.

### GUIDED timeout

After the last setpoint the boat held ~1.5 m/s for ~4 s, then decelerated, effectively
stopping **6.3 s** after the last setpoint:

```
[timeout] t+ 1.0s  speed ~1.51 m/s
[timeout] t+ 3.2s  speed ~1.51 m/s
[timeout] t+ 4.7s  speed ~1.13 m/s
[timeout] t+ 5.8s  speed ~0.34 m/s
[timeout] t+ 6.3s  speed ~0.03 m/s   <- effectively stopped
```

The cause is **hardcoded, not a parameter** — `GUID_TIMEOUT` does not exist on Rover 4.7.1.
`Rover/mode_guided.cpp` lines 55 and 79:

```c
if (have_attitude_target && (millis() - _des_att_time_ms) > 3000) {
```

A **3000 ms** guided-target timeout, after which the boat decelerates (~3 s more to coast
down). **Consequence for Nav2:** the bridge node must republish `cmd_vel` at well above
1/3 Hz — 10 Hz was used here — or the boat will stall every 3 seconds.

## TF tree

| Topic | Publisher | Contents |
|---|---|---|
| `/tf` | node `mavros` (1 publisher) | **nothing** — `ros2 topic hz /tf` over 8 s produced no messages at all |
| `/tf_static` | `mavros` | `map → map_ned`, `odom → odom_ned`, `base_link → base_link_frd` |

**MAVROS does not publish dynamic TF by default.** The only transforms present are the three
static ENU↔NED/FRD aliases. There is no `map → odom → base_link` chain, so nothing currently
provides the transform Nav2 will need.

As instructed, this is reported only — the tree has not been redesigned. Note that MAVROS's
per-plugin `tf.send` settings did not appear as readable parameters
(`local_position.tf.send` → "Parameter not set"), so enabling them will need a look at this
MAVROS version's config schema.

### Sim time

| Node | `use_sim_time` |
|---|---|
| `/mavros` | **True** |
| `/sim_bridge` | **False** — intentional |

The bridge is the process publishing `/clock`, so making it wait on `/clock` would be
circular. Every other node in the graph should be launched with `use_sim_time:=true`.

## One-command bringup

`launch_blueboat.sh` now starts all four components with a single trap for clean shutdown:

```
./launch_blueboat.sh              # everything, Gazebo GUI + MAVProxy console/map
HEADLESS=1 ./launch_blueboat.sh   # everything, no GUI, no MAVProxy console/map
WITH_ROS=0 ./launch_blueboat.sh   # Gazebo + SITL only (pre-Step-1c behaviour)
QGC=1 ./launch_blueboat.sh        # also start QGroundControl (needs a display)
```

Observed startup:
```
[launch] world:    /home/simuser/sim_scratch/blueboat_waves.sdf
[launch] params:   /home/simuser/sim_scratch/blueboat.parm
[launch] home:     40.2386,-111.7353,1368,0
[launch] headless: 1   with_ros: 1
[launch] Gazebo started (pid 59), log: /tmp/gz_blueboat.log
[launch] ArduPilot plugin loaded.
[launch] SITL started (pid 86)
[launch] ros_gz_bridge started (pid 87), log: /tmp/sim_bridge.log
[launch] MAVROS started (pid 165) on udp://127.0.0.1:14551@, log: /tmp/mavros.log
[launch] MAVLink: tcp:5760 (primary), 5762/5763 (aux), UDP out: 127.0.0.1:14550 127.0.0.1:14551
```

Shutdown kills MAVROS, the bridge, SITL and Gazebo, then `pkill`s `bin/ardurover`,
`mavros_node`, `parameter_bridge` and `gz sim` — because `sim_vehicle.py` and `ros2 launch`
both spawn children that survive a TERM to the parent, and a surviving `ardurover` keeps
host-global ports 5760-5763 bound (which is what caused the repeated
"bind failed on port 5760" failures in Steps 1a/1b).

New/changed files this step:
- `Dockerfile.sim` — version ARGs, `iproute2`, MAVROS + geographiclib datasets, QGC AppImage
- `launch_blueboat.sh` — bridge + MAVROS + QGC, `WITH_ROS`/`QGC`, working `ss` check, stdin fix
- `bridge.yaml`, `launch/sim_bridge.launch.py` — ros_gz_bridge
- `launch/mavros_sim.launch.py` — MAVROS with forced sim time
- `ros_control_test.py` — ROS-only control test harness

## QGroundControl

### Pinned install

Stable candidates: **v5.1.4** (latest stable — chosen), v5.1.3 (stable), v5.1.0.
v5.1.2 was excluded as a release candidate (`prerelease: true`).

```dockerfile
ARG QGC_VERSION=v5.1.4
ARG QGC_SHA256=1c4ac089abfaac6c6fcd75c7b477ea18da1bc3592cddca5ab1a19c1a13410e65
```

**Upstream publishes no checksum or signature.** The v5.1.4 assets are only the two
AppImages, the `.dmg`, the `.apk` and the two `.exe` installers — there is no
`*.sha256` / `SHA256SUMS`. So `QGC_SHA256` is a **trust-on-first-use** pin: the hash of the
exact 187 MB artifact downloaded and tested here, enforced with `sha256sum -c` during the
build so it fails loudly if those bytes ever change. That is the reproducibility guarantee
we can actually make; it is not upstream provenance.

Containers normally lack FUSE, so the AppImage is **self-extracted** with
`--appimage-extract` into `/opt/qgroundcontrol` and run through its `AppRun`, with a
`/usr/local/bin/qgroundcontrol` launcher on PATH. Extraction runs as root (just unsquashfs,
no QGC code executes), but the launcher runs as `simuser` — **QGC refuses to run as root**,
and the bringup script checks `id -u` and refuses with a clear message rather than letting
QGC fail on its own.

Runtime deps added for the Qt6 AppImage: `libxcb-xinerama0`, `libxcb-cursor0`,
`libxkbcommon-x11-0`, `libpulse0`, `libgl1`, `wget`. GStreamer (for QGC video) was already
present from the ardupilot_gazebo step.

### Coexistence with MAVROS — verified, no interference

`QGC=1 ./launch_blueboat.sh` starts QGC with the same display environment as Gazebo
(`DISPLAY` + the `/tmp/.X11-unix` mount, `QT_QPA_PLATFORM=xcb`).

```
UNCONN 0 0   0.0.0.0:14550 0.0.0.0:* users:(("QGroundControl",pid=315,fd=80))
UNCONN 0 0 127.0.0.1:14551 0.0.0.0:* users:(("mavros_node",pid=353,fd=21))
```

QGC auto-connected on **UDP 14550** while MAVROS held **14551**, and both stayed connected
at once (QGC showing the vehicle with live telemetry, confirmed visually).

With both attached:

| Check | Result |
|---|---|
| `/mavros/state` | `connected: true` throughout |
| ROS-issued `set_mode GUIDED` | took effect (`MANUAL` → `GUIDED`) |
| `/mavros/local_position/odom` rate | 3.60 Hz (vs 3.78 Hz MAVROS-only — within noise) |

**No interference observed.** MAVProxy fans the same stream to two separate UDP endpoints,
so the two GCSs never contend for a port. The real caveat is not technical but operational:
they are two independent control authorities on one vehicle — either can arm, disarm or
change mode — so who is driving should be agreed out-of-band.

Minor observation: `ps` shows `--out 127.0.0.1:14550` **twice**, because `sim_vehicle.py`
adds its own default 14550 output on top of the one the script passes. Harmless (duplicate
output to the same endpoint), but it means 14550 is live even without the explicit
`MAVLINK_OUTS` entry.

Native macOS/Windows install instructions for the same pinned v5.1.4 — including how a
native QGC reaches the sim across Docker Desktop's VM boundary — are documented in
`SETUP_LOG.md` (documented only, not tested, as requested).

## Problems

**0. GUI launch path was silently killing SITL (latent since Step 1b — now fixed)**
Symptom: with `QGC=1` (which implies the non-headless path) SITL started and immediately died:
```
SIM_VEHICLE: MAVProxy exited
SIM_VEHICLE: Killing tasks
```
Step 1b had attributed this to "no stdin under `docker exec -d`" and fixed only the
HEADLESS path with `--mavproxy-args=--daemon`. That diagnosis was incomplete. The real
cause is that **bash redirects a background job's stdin to `/dev/null`**, so
`( ... sim_vehicle.py --console --map ) &` never receives the script's stdin — meaning the
interactive MAVProxy console would hit EOF and die *even when run from a real terminal*.
Fix: hand the backgrounded subshell the script's stdin explicitly:
```bash
( cd "${HOME}/ardupilot" && sim_vehicle.py "${SITL_ARGS[@]}" --console --map ) <&0 &
```
After the fix, MAVProxy exit count went from 1 to 0 and the full GUI stack stays up.
This is worth flagging because the GUI path was the *default* mode and had never been
verified end to end.

**1. `git describe` reports `APMrover2-beta`, not `Rover-4.7.1`**
~20 tags point at the 4.7.1 commit, so `describe` picks one alphabetically. Resolved by
verifying `rev-parse HEAD` against `git ls-remote` and reading `THISFIRMWARE`. Flagged so
nobody later "fixes" a pin that was never broken.

**2. `/mavros/param/get` does not exist in this MAVROS version**
```
waiting for service to become available...
failed to check service availability: rcl node's context is invalid, at ./src/rcl/node.c:404
```
FCU parameters are exposed as ROS 2 parameters on a `/mavros/param` node instead. Correct
usage:
```bash
ros2 service call /mavros/param/pull mavros_msgs/srv/ParamPull "{force_pull: true}"
ros2 param get /mavros/param FRAME_CLASS
```

**3. `armed: false` immediately after a successful arm call**
`/mavros/state` publishes at only 0.94 Hz, so `ros2 topic echo --once` caught a stale
message. Not a real failure — wait for the next state message.

**4. Carried over and now fixed:** Step 1b Problem 9 (`ss` missing in the container, so the
port pre-flight check silently never fired) is resolved by installing `iproute2`.

## Open questions

1. **MAVROS position rate is 3.8 Hz** — almost certainly too slow for Nav2. Raise via
   `SRx_POSITION` or `/mavros/set_message_interval`? Worth deciding the target rate
   (20–50 Hz?) before Nav2 work.
2. **No dynamic TF.** Nav2 needs `map → odom → base_link`. Options: enable MAVROS's TF
   publishing, or write a small node that republishes `/mavros/local_position/odom` as TF.
   This is the biggest structural decision left before Nav2.
3. **The 3 s guided timeout is hardcoded**, so a Nav2 bridge node must stream `cmd_vel`
   continuously and should probably publish zero-velocity keepalives when Nav2 is idle.
   Worth deciding whether that node lives in the sim repo or the team repo.
4. **Tuning is still outstanding** from Step 1b (cross-track mean 12.6 m on 25 m legs; the
   9–22° body-velocity heading errors here are the same underlying issue). Nav2 will sit on
   top of this behaviour, so tuning probably wants to happen first.
5. **`/clock` at 939 Hz** is chatty. Gazebo's 1 ms physics step drives it. Worth throttling
   for teammates on slower machines?
6. **Image size** — now larger again with MAVROS. Still a single-stage build. Worth
   addressing before teammates pull it?
7. **Two image tags exist** (`:latest` = Step 1b, `:1c` = pinned). Which becomes the one the
   team pulls, and should it be pushed to a registry?
8. **QGC has no upstream checksum.** The TOFU pin protects against silent artifact
   changes but not against a compromised original upload. Acceptable for a scratch sim;
   worth a conscious decision before this ships to the whole team.
9. **Two control authorities.** QGC and MAVROS can both arm/disarm and change mode on the
   same vehicle. Fine for debugging, but the team should agree who drives — and it is worth
   deciding whether QGC should default to on or off for teammates.
10. **Still out of scope:** sensors (LiDAR/camera), Nav2, RoboBoat course elements.
