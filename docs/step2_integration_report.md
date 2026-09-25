# Step 2 Report — connecting y_boat_core to the BlueBoat simulator

Goal: run the team's own ROS 2 code from `y_boat_core` against the scratch simulator, so
teammates can develop nodes against a real vehicle loop.

**Outcome: working.** `boat_control`'s `drive_test` node arms the simulated BlueBoat, drives
it under body-frame velocity control, and reports closed-loop displacement. The two
containers (`boat_dev` and the sim) talk over a shared DDS graph.

Unlike Steps 1a–1c, this step **did** modify `y_boat_core`. Three files changed; all are
committed on branch `ben/sim-connection`.

## What was wrong, and what fixed it

Three independent problems had to be solved. Each failed *silently* rather than loudly,
which is what made them expensive.

### 1. No MAVROS in the team image

`boat_control/sim_node.py` has a graceful fallback:

```python
try:
    from mavros_msgs.msg import State, PositionTarget
    HAS_MAVROS = True
except ImportError:
    HAS_MAVROS = False
```

The published `yrobotics/y_boat_core:latest` has no `mavros_msgs`, so `HAS_MAVROS` was
False and the node fell through to publishing `geometry_msgs/Twist` on
`/mavros/setpoint_velocity/cmd_vel_unstamped`. **That topic is interpreted in the world ENU
frame**, so the boat drives in a fixed compass direction regardless of heading. The node
logs a cheerful "Using standard ROS 2 geometry_msgs interface" and the drive test can still
report SUCCESS, because it only measures distance travelled — not direction.

**Fix:** added `ros-${ROS_DISTRO}-mavros`, `ros-${ROS_DISTRO}-mavros-extras` and the
GeographicLib geoid datasets to `.docker/dockerfile.dev`. With MAVROS present the node
takes the `/mavros/setpoint_raw/local` + `FRAME_BODY_NED` path, which is true body-frame
control.

The geoid datasets are not optional — without them the mavros node exits at startup.

### 2. Cross-container DDS: discovery worked, data didn't

The more interesting failure. Symptom:

```
ros2 topic list   ->  topics appear
ros2 topic echo   ->  silence
```

Cause: ROS 2 Jazzy's Fast DDS runs two transports. **UDP** handles discovery and remote
traffic; **shared memory** handles peers it decides are on the same host, because it is
much faster than looping through the kernel network stack.

Both containers run `--network host`, so discovery succeeded and each saw the other's
topics. Fast DDS then compared host IDs, concluded "same machine", and switched to shared
memory for the actual data. Shared memory lives in `/dev/shm`, which belongs to the **IPC
namespace** — and Docker gives each container a *private* IPC namespace by default. The sim
wrote segments into its `/dev/shm`; `boat_dev` looked in a different one and found nothing.

The sim container already ran with `--ipc host`. `boat_dev` did not. That asymmetry was the
entire bug.

Measured, three ways:

| `boat_dev` IPC | Workaround | Result |
|---|---|---|
| private | none | nothing received |
| private | force Fast DDS to UDP-only | works |
| **host** | none | **works** |

The middle row is what proves the diagnosis: disabling shared memory entirely also fixes
it, so shared memory is definitively the broken path.

**Fix:** `ipc: host` in `docker-compose.yml`.

This is better than forcing UDP-only because it keeps shared memory *working* rather than
switching it off. That matters later — once camera or LiDAR topics exist, SHM avoids
serialising megabytes through loopback. It also fixes it for every node in the container,
not just one.

`sim_node.py` previously carried a 27-line hand-written Fast DDS XML profile to force
UDPv4. With `ipc: host` in place that became dead code and has been removed. Worth noting
the same effect was achievable with a single env var (`FASTDDS_BUILTIN_TRANSPORTS=UDPv4`)
rather than a generated XML file — but the namespace fix is better than either.

### 3. ROS not sourced in `docker exec` shells

`entrypoint.sh` sources ROS for PID 1 only, so `docker exec -it boat_dev bash` landed in a
half-configured environment. Combined with a stale second colcon overlay in `src/`
(`src/build`, `src/install`, `src/log`, left over from someone building inside `src/`
instead of `/workspace`), it was ambiguous which environment you actually had.

**Fix:** source the ROS underlay and workspace overlay from `/root/.bashrc` in the
Dockerfile, and delete the stale overlay. `src/` now contains only `nodes/`.

One residual sharp edge: `.bashrc` sources `/workspace/install/setup.bash` only if it
exists *at shell start*. On a fresh container it does not, so after your first
`colcon build` you must source it once by hand. Shells opened after that get it
automatically.

## Changes to y_boat_core

Branch `ben/sim-connection` (renamed from `ben-readme`, which undersold it — the branch
carries the Docker comms and sim integration, not just docs). Local only; no upstream yet.

| File | Change |
|---|---|
| `.docker/dockerfile.dev` | MAVROS + mavros-extras + geoid datasets; ROS sourced from `.bashrc`; merged apt layers; `ARG BASE_IMAGE` now actually used by `FROM` |
| `docker-compose.yml` | `ipc: host` |
| `src/nodes/boat_control/boat_control/sim_node.py` | removed the 27-line Fast DDS XML workaround |
| `README.md` | build/run instructions, simulator section |

Deleted (gitignored build artifacts, not tracked): `src/build`, `src/install`, `src/log`.

## Verified state

Checked live, with the XML workaround removed:

```
boat_dev IpcMode           = host
/mavros/state              -> connected: true, mode: HOLD, armed: false
/mavros/local_position/odom -> 3.68 Hz, flowing across containers
```

Earlier end-to-end drive test result:

```
Starting Coordinate : (0.00, 0.30)
Ending Coordinate   : (-0.01, 7.47)
Distance Traveled   : 7.17 meters
[SUCCESS] Closed-loop control verified with simulation!
```

Also verified: colcon discovers packages anywhere under `/workspace/src`, not just
`src/nodes/` — tested with one package in `src/nodes/` and one in `src/interfaces/`; both
built and appeared in `ros2 pkg list`. The `src/nodes/` layout is convention, not a
constraint.

## How to run it

```bash
# Terminal 1 (host) - simulator
cd ~/y_boat/sim_scratch && ./run_sim_scratch.sh

# Terminal 2 (host) - team container
cd ~/y_boat/y_boat_core
docker build -f .docker/dockerfile.dev -t yrobotics/y_boat_core:mavros-local .   # first time
./scripts/run.sh -i

# Inside boat_dev
cd /workspace
colcon build --symlink-install --packages-select boat_control
source /workspace/install/setup.bash     # needed after the first build only
ros2 run boat_control drive_test
```

Do **not** pass `-p` to `run.sh` — it pulls the published image, which has no MAVROS.

Sanity check before running: `ros2 topic echo /mavros/state --once` should show
`connected: true`. If it hangs, confirm `ROS_DOMAIN_ID` is 10 in both containers.

## Problems

1. **`boat_control` silently used world-frame control** — no error, and the drive test
   could still print SUCCESS because it only checks distance, not direction. The most
   dangerous failure of the three.
2. **DDS half-connected** — topics listed but never delivered. Diagnosed to IPC namespace
   isolation (above).
3. **`ros2: command not found` after sourcing an overlay** — reported during setup. I could
   **not** reproduce it in a clean container and do not have a confirmed root cause. The
   contributing factor was two competing overlays (`/workspace/install` and
   `/workspace/src/install`); removing the stale one eliminated the ambiguity, but the exact
   mechanism is unexplained.
4. **`scripts/run.sh` failed with `DOCKER_IMAGE: not set in .env`** — the rewritten script
   requires `DOCKER_IMAGE` and `ROS_DISTRO`, which existing `.env` files predating the
   change do not have. `.env-example` has both, so fresh clones are fine.
5. **Process mistakes on my side, corrected:** I deleted `scripts/run_local.sh` (a committed
   file, restored) and dropped the chown TIP from the README (restored). I also created
   `run_local.sh` as a workaround that later became redundant once `run.sh` was rewritten to
   make pulling opt-in.

## Open questions

1. **Publishing the image is the blocker for everyone else.** MAVROS exists only in a local
   build. A teammate cloning the repo gets `DOCKER_IMAGE=latest`, the published image with
   no MAVROS, and lands straight in the silent world-frame fallback. Either push, or add a
   `build:` section to compose so `docker compose build` works.
2. **`dockerfile.nano` has no MAVROS.** ROS Humble for the Jetson, so `ros-humble-mavros`
   and a different geoid script path. The actual target hardware cannot run `boat_control`
   until this is done.
3. **Body-frame control is not yet conclusively verified.** The drive test moved almost
   purely +Y, which is consistent with body-frame control *and* with world-frame. One run
   from a rotated heading settles it.
4. **README still claims "this image ships mavros"** — true only for the local build, not
   the published one that `.env-example` points at.
5. **MAVROS position topics run at ~3.7 Hz** — ArduPilot's default stream rate, likely too
   slow for Nav2.
6. **No dynamic TF** (from Step 1c, unchanged): MAVROS publishes only static ENU/NED
   aliases, so there is no `map -> odom -> base_link`. This remains the main structural
   blocker for Nav2.
7. **Tuning still outstanding** — cross-track error averaged 12.6 m on 25 m legs in Step 1b.
   Nav2 will sit on top of that behaviour.
