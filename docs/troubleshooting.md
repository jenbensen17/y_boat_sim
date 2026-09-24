# Troubleshooting

Start here when something does not come up. Every component writes a log inside the
container, so the fastest first move is almost always to read the relevant one.

## Where the logs are

All paths are **inside the container** (`docker exec -it y_boat_sim bash`, or
`docker exec y_boat_sim cat <path>` from the host):

| Component | Log |
|---|---|
| Gazebo | `/tmp/gz_blueboat.log` |
| `ros_gz_bridge` | `/tmp/sim_bridge.log` |
| MAVROS | `/tmp/mavros.log` |
| QGroundControl | `/tmp/qgc.log` |
| ArduPilot SITL / MAVProxy | the `xterm` window it runs in |

---

## "port 5760 already in use" / the sim refuses to start

A previous run is still alive. `launch_blueboat.sh` checks ports 5760, 5762 and 5763
before starting and stops early rather than failing confusingly later.

```bash
docker stop y_boat_sim          # usual cause: a container still running
docker rm -f y_boat_sim         # if it is wedged
```

If the ports are held by something on the **host** rather than the container:

```bash
ss -ltnp | grep -E ':(5760|5762|5763)'
pkill -f ardurover; pkill -f sim_vehicle.py
```

`run_sim.sh` warns about these ports at startup but does not kill anything for you.

---

## No windows appear

1. **`$DISPLAY` was empty.** `run_sim.sh` prints
   `No DISPLAY variable found; running in HEADLESS mode` and continues without GUIs.
   That is the intended fallback over SSH and in CI. Run from a desktop session, or
   forward X11.
2. **X11 permissions.** On Linux the launcher runs `xhost +SI:localuser:$(id -un)`
   and revokes it on exit. If your setup needs the broader grant:
   `XHOST_MODE=fallback ./run_sim.sh`.
3. **Windows/WSL2.** Update WSLg from PowerShell, then relaunch:
   ```powershell
   wsl --update
   wsl --shutdown
   ```
4. **macOS.** You need XQuartz with *"Allow connections from network clients"*, or
   use the recommended headless + native QGC workflow in
   [platforms.md](platforms.md).

---

## QGroundControl does not open

`launch_blueboat.sh` skips QGC (with a printed reason) in three cases:

- `HEADLESS=1` — there is no display to draw on.
- `qgroundcontrol` is not on `PATH` — rebuild the image with `./build_sim.sh`.
- The container is running as **root** — QGC hard-refuses to run as root.

Otherwise check `/tmp/qgc.log`. QGC auto-connects on UDP **14550**; MAVROS holds
**14551**. Nothing else should bind 14550.

---

## MAVROS never connects / `/mavros/state` shows `connected: false`

`launch_blueboat.sh` waits 10 s after SITL before starting MAVROS, but a slow machine
can still lose the race. Check `/tmp/mavros.log` for repeated heartbeat timeouts, and
confirm SITL actually came up in the ArduPilot `xterm`. Restarting with `Ctrl+C` and
`./run_sim.sh` is usually enough.

---

## The image is missing

`run_sim.sh` tries to pull it automatically. If that fails:

```bash
docker pull jenbensen17/y_boat_sim:latest   # fastest
./build_sim.sh                              # build from source, ~5-7 min
BUILD_IF_MISSING=1 ./run_sim.sh             # build automatically if absent
```

---

## Gazebo's 3D window is unusably slow

Drop the 3D view but keep QGroundControl and the ArduPilot terminal. Physics still
runs at full rate:

```bash
./run_sim.sh --no-gz-gui
```

---

## `./test_ros.sh` says the container is not running

The test attaches to a live simulator; it does not start one. Launch `./run_sim.sh`
first, wait for the `Simulator is READY!` banner, then run the test in a second
terminal.

---

## Another container cannot see the sim's ROS 2 topics

Both sides must share `ROS_DOMAIN_ID` (the sim uses **10**) and run on the host
network. The sim also forces DDS onto plain UDP via `sim/fastdds_udp.xml`
(`useBuiltinTransports=false`), which is what makes discovery work reliably across
container boundaries — shared-memory transport does not cross them. If your own
container overrides `FASTRTPS_DEFAULT_PROFILES_FILE`, point it at an equivalent
profile. See [y_boat_core-integration.md](y_boat_core-integration.md).

---

## The boat stops moving on its own after ~3 seconds

That is ArduPilot's guided-mode timeout, not a bug. Velocity setpoints must be
published continuously at 10 Hz or faster — see rule 2 in
[ros2-development.md](ros2-development.md).
