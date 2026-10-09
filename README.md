# BlueBoat Autonomous Surface Vessel (ASV) Simulator

[![ROS 2 Jazzy](https://img.shields.io/badge/ROS_2-Jazzy-blue.svg)](https://docs.ros.org/en/jazzy/)
[![Gazebo Harmonic](https://img.shields.io/badge/Gazebo-Harmonic-orange.svg)](https://gazebosim.org/docs/harmonic)
[![ArduPilot Rover](https://img.shields.io/badge/ArduPilot-Rover--4.7.1-green.svg)](https://ardupilot.org/rover/)

The official standalone simulation environment for the **BYU Robotics Association RoboBoat Team**. This repository provides a complete, hardware-in-the-loop-equivalent software simulator for the BlueBoat autonomous surface vessel.

It runs **Gazebo Harmonic**, **ArduPilot SITL (`Rover-4.7.1`)**, **`asv_wave_sim` hydrodynamics**, **`ros_gz_bridge`** and **MAVROS** in one Docker container. Gazebo is shown in your web browser; **QGroundControl** and the ArduPilot console run as windows on your desktop. It works the same on **Windows**, **macOS** and **Linux**.

---

## Quickstart

You need **Docker** ([Docker Desktop](https://www.docker.com/products/docker-desktop/) on Windows/macOS, Docker Engine on Linux), **Python 3**, and [**QGroundControl**](https://docs.qgroundcontrol.com/master/en/qgc-user-guide/getting_started/download_and_install.html) (the normal installer for your OS).

```bash
git clone https://github.com/jenbensen17/y_boat_sim.git
cd y_boat_sim
python sim.py start
```

The first start downloads and builds the image (several GB, once). After that it starts in about a minute and opens:

1. **Gazebo** in your browser at **http://localhost:6080**: the 3D boat on the water. Click and drag to look around.
2. **QGroundControl** on your desktop: map, telemetry and the waypoint planner. It connects to the sim by itself (UDP 14550, its default).
3. **ArduPilot console** in a new terminal window: MAVProxy at a `MANUAL>` prompt. Closing the window doesn't stop anything; `python sim.py console` reopens it.

Check that ROS 2 can drive the boat:

```bash
python sim.py test
```

Stop it with `python sim.py stop`.

> [!TIP]
> On macOS and some Linux setups the command is `python3`, not `python`.

---

## Commands

```bash
python sim.py start               # Gazebo in the browser, QGC + ArduPilot console on your desktop
python sim.py start --no-gazebo   # no Gazebo (lighter; physics still runs)
python sim.py start --no-qgc      # don't open QGroundControl
python sim.py start --no-console  # don't open the ArduPilot console window
python sim.py start --cpu         # skip the GPU even if one works
python sim.py start --world sim/blueboat_waves.sdf   # full wave world (see Performance)
python sim.py stop
python sim.py status              # running? GPU or CPU rendering?
python sim.py console             # ArduPilot console in this terminal (Ctrl+B, D to leave)
python sim.py test                # ROS 2 drive test
python sim.py logs                # follow the sim's output
python sim.py shell               # bash inside the sim, with ROS 2 sourced
```

---

## GPU or CPU

`sim.py start` tells you which one it picked:

```
[sim] Rendering on your GPU: D3D12 (NVIDIA GeForce RTX 2080 Ti)
```

| Your machine | Gazebo in the browser |
|---|---|
| **Windows** (Docker Desktop or WSL2), any GPU including Intel/AMD integrated | **GPU**, smooth (~75 FPS on an RTX 2080 Ti) |
| **macOS** | CPU: Docker on macOS has no GPU access |
| **Linux** | CPU for now: the container's virtual display can't use the GPU yet |

On the CPU, `sim.py` switches to simpler graphics (the lighter `ogre` renderer, flat
water, 2 render threads). Gazebo then runs at ~18 FPS while the physics stays at real
time (measured on an 8-core laptop CPU). If the boat still lags on a slower machine,
use `python sim.py start --no-gazebo` and follow it in QGroundControl.

After starting on the GPU, `sim.py` checks that Gazebo's view actually draws. Some
drivers accept GPU rendering but produce a black screen (seen on an AMD Radeon 880M);
then it restarts in CPU mode by itself. If a Windows machine ends up on the CPU,
update the Windows GPU driver and run `wsl --update` in PowerShell, then try again.

---

## Connecting your own code

ROS 2 runs inside the container on domain **10** with the UDP-only DDS profile
`sim/fastdds_udp.xml`. The simplest way to run your nodes against it is from
`python sim.py shell`; the repo is mounted at `~/sim_scratch` inside the container.

If QGroundControl doesn't pick the boat up by itself (UDP 14550 blocked, or Docker
Engine inside WSL instead of Docker Desktop), connect it over TCP instead:
**Application Settings → Comm Links → Add → TCP**, server `localhost`, port `5762`.

---

## Performance Notes

Measured on WSL2 + RTX 2080 Ti: Gazebo at ~75 FPS, physics below 0.8× real time
under 1% of the time.

- **Lite world by default** (`sim/blueboat_waves_lite.sdf`). It drops the server-side
  renderer and the animated wave mesh, and uses a coarser wave field. With
  `wind_speed` 0 the water is flat either way. The full world
  (`sim/blueboat_waves.sdf`) stalls the physics noticeably.
- **Physics steps at 4 ms (250 Hz)** instead of Gazebo's 1 ms default. With ArduPilot's
  lock-step, every physics step waits on SITL, so 1 kHz meant constant stalls.
- **`/clock` is republished at 50 Hz** (`sim/launch/clock_throttle.py`). Gazebo sends it
  every physics step, and MAVROS's ~59 nodes each process it; at full rate that cost
  ~1.8 cores.
- **A lightweight BlueBoat** (`sim/models/blueboat_lite`): the same model with its visual
  meshes simplified from ~277k to ~12.7k triangles. Physics, plugins and topics are
  unchanged. Rendering the full CAD meshes was what held CPU-only Gazebo to ~9 FPS.
- **Without a GPU:** the `ogre` renderer instead of `ogre2`, flat water instead of the
  wave mesh, and Mesa limited to 2 render threads. Its default of one thread per core
  starved the physics (below 0.8× real time 35% of the time, versus under 1% with 2).

| CPU rendering | Gazebo FPS | Physics below 0.8× real time |
|---|---|---|
| Original setup | ~6 | ~10% |
| Now | ~18 | <1% |

---

## Repository Layout

```
sim.py              The launcher.  ← the one you'll use
compose.yaml        The container: sim + Gazebo in the browser on port 6080
compose.gpu-wsl.yaml  GPU add-on for Windows (sim.py adds it when the GPU works)
docker/desktop.Dockerfile  Browser desktop layer on top of the sim image
Dockerfile.sim      The base sim image (ROS 2, Gazebo, ArduPilot, MAVROS, QGC)
test_ros.sh         The ROS 2 drive test (run via `python sim.py test`)

sim/
  desktop/start_desktop.sh  virtual display + noVNC for Gazebo, then the sim
  launch_blueboat.sh        brings up Gazebo + SITL + bridge + MAVROS
  blueboat_waves_lite.sdf   the default world (boat + hydrodynamics)
  blueboat_waves.sdf        the full wave world
  blueboat.parm             ArduPilot parameters
  blueboat_mission.txt      sample 25 m rectangular search pattern
  bridge.yaml               ros_gz_bridge topic mapping
  fastdds_udp.xml           DDS over UDP only
  launch/                   ROS 2 launch files (bridge, clock throttle, MAVROS)
  models/blueboat_lite/     the BlueBoat with simplified visual meshes

tests/              test_boat_drive.py, the automated drive test
docs/               Guides and build history
```

---

## Documentation

| Guide | Read it when |
|---|---|
| [docs/ros2-development.md](docs/ros2-development.md) | You're writing ROS 2 nodes or Nav2 against the sim. **Start here.** |
| [docs/y_boat_core-integration.md](docs/y_boat_core-integration.md) | You want your `y_boat_core` autonomy stack driving this boat. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Something didn't come up. |
| [docs/](docs/README.md) | Build history and step reports. |

---

## Why We Use These Three Core Tools

| Tool | Role | Why We Chose It | How It Helps Us |
|---|---|---|---|
| **Gazebo Harmonic** | **Virtual Lake** *(Physics & World)* | Accurate fluid dynamics, water buoyancy, wave interaction (`asv_wave_sim`), and thruster response. | Replaces the physical lake. Allows testing collision avoidance, rough water stability, and thruster limits with zero risk to hardware. |
| **ArduPilot SITL + Terminal** | **Autopilot Brain** *(Low-Level Control)* | Line-for-line identical firmware (`Rover-4.7.1`) to the real boat's Pixhawk/Cube computer. Battle-tested EKF3 state estimation and skid-steer thruster mixing. | Any ROS 2 autonomy code that works in SITL works on the physical boat with zero firmware changes. The terminal gives engineers instant access to change modes (`mode GUIDED`), arm thrusters, and tune 1,000+ parameters live. |
| **QGroundControl (QGC)** | **Shore Station** *(Operator Mission Control)* | Global standard ground control station communicating over MAVLink. Rich satellite map, HUD, battery voltage, and waypoint planner. | Gives human operators complete situational awareness. Allows drawing and uploading autonomous GPS waypoint routes for competition tasks, plus instant safety overrides (Return-to-Launch or manual joystick takeover). |
