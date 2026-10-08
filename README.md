# BlueBoat Autonomous Surface Vessel (ASV) Simulator

[![ROS 2 Jazzy](https://img.shields.io/badge/ROS_2-Jazzy-blue.svg)](https://docs.ros.org/en/jazzy/)
[![Gazebo Harmonic](https://img.shields.io/badge/Gazebo-Harmonic-orange.svg)](https://gazebosim.org/docs/harmonic)
[![ArduPilot Rover](https://img.shields.io/badge/ArduPilot-Rover--4.7.1-green.svg)](https://ardupilot.org/rover/)

The official standalone simulation environment for the **BYU Robotics Association RoboBoat Team**. This repository provides a complete, hardware-in-the-loop-equivalent software simulator for the BlueBoat autonomous surface vessel.

It brings together **Gazebo Harmonic**, **ArduPilot SITL (`Rover-4.7.1`)**, **`asv_wave_sim` hydrodynamics**, **`ros_gz_bridge`**, **MAVROS**, and **QGroundControl**, installed natively on **Ubuntu 24.04** so Gazebo runs as a normal app on your GPU. On Windows that's a WSL2 distro.

---

## Quickstart

**1. Get Ubuntu 24.04.** Native Linux works as is. On Windows, open PowerShell and run:

```powershell
wsl --update
wsl --install -d Ubuntu-24.04
```

It asks you to create a username and password; that password is what setup will ask for.

**2. Install (once, ~20–40 min).** In the Ubuntu 24.04 terminal:

```bash
git clone https://github.com/jenbensen17/y_boat_sim.git ~/y_sim
cd ~/y_sim
./setup_native.sh
```

It installs ROS 2 Jazzy, Gazebo Harmonic, MAVROS, ArduPilot SITL, the wave/hydrodynamics
plugin, the BlueBoat model and QGroundControl. Packages come from apt; everything else
goes in `~/blueboat_deps`. It's safe to re-run: finished steps are skipped.

**3. Run:**

```bash
./start_sim.sh
```

Then, in a second terminal, check that ROS 2 can drive the boat:

```bash
./test_ros.sh
```

Press `Ctrl+C` in the first terminal to shut everything down.

> [!IMPORTANT]
> **Windows/WSL users**: clone inside the Linux filesystem (`~/y_sim`), **never**
> under `/mnt/c/...`.

### What opens

1. **Gazebo Sim**: the 3D boat on the water.
2. **QGroundControl**: telemetry, map and the waypoint planner.
3. **ArduPilot terminal** (`xterm`): a live MAVProxy console at a `MANUAL>` prompt.

### GPU check

`start_sim.sh` prints the renderer when it starts:

```
[start_sim] OpenGL renderer: D3D12 (NVIDIA GeForce RTX 2080 Ti)
```

That should name your GPU; integrated Intel/AMD graphics count. On WSL it switches to
the GPU automatically (Mesa's `d3d12` driver) when it works.

If it says **`llvmpipe`**, Gazebo is drawing on the CPU and will be choppy. It also
prints a warning:

- **WSL:** run `wsl --update` in PowerShell and update your Windows GPU driver, then
  restart WSL (`wsl --shutdown`).
- **Native Linux:** make sure you're in the `render` and `video` groups
  (`sudo usermod -aG render,video $USER`, then log out and back in).
- **No GPU at all** (VMs, servers): run `GZ_GUI=0 ./start_sim.sh`. Physics still runs
  at full speed and QGroundControl shows the boat on the map; you just skip the
  Gazebo window.

---

## Common Commands

```bash
./start_sim.sh                  # everything: Gazebo + QGC + ArduPilot terminal + ROS 2
GZ_GUI=0 ./start_sim.sh         # no Gazebo window (physics still runs)
QGC=0 ./start_sim.sh            # no QGroundControl
HEADLESS=1 ./start_sim.sh       # no windows at all
WORLD=$PWD/sim/blueboat_waves.sdf ./start_sim.sh   # full wave world (see below)

./test_ros.sh                   # automated ROS 2 drive test (sim must be running)
./setup_native.sh               # re-run after pulling changes to the pinned versions
```

ROS 2 uses domain **10** with the UDP-only DDS profile in `sim/fastdds_udp.xml`; your
own nodes need the same settings to see the sim's topics:

```bash
source /opt/ros/jazzy/setup.bash
export ROS_DOMAIN_ID=10
export FASTRTPS_DEFAULT_PROFILES_FILE=~/y_sim/sim/fastdds_udp.xml
export RMW_FASTRTPS_USE_QOS_FROM_XML=1
```

---

## Performance Notes

The defaults are tuned so the sim holds real time on an ordinary laptop. Measured on
WSL2 + RTX 2080 Ti: the Gazebo window at ~73 FPS, physics below 0.8× real time only
~2% of the time.

- **Lite world by default** (`sim/blueboat_waves_lite.sdf`). It drops the server-side
  renderer and the animated wave mesh, and uses a coarser wave field. With
  `wind_speed` 0 the water is flat either way. The full world
  (`sim/blueboat_waves.sdf`) stalls the physics noticeably; use `WORLD=` to pick it.
- **Physics steps at 4 ms (250 Hz)** instead of Gazebo's 1 ms default. With ArduPilot's
  lock-step, every physics step waits on SITL, so 1 kHz meant constant stalls.
- **`/clock` is republished at 50 Hz** (`sim/launch/clock_throttle.py`). Gazebo sends it
  every physics step, and MAVROS's ~59 nodes each process it; at full rate that cost
  ~1.8 cores.

---

## Repository Layout

```
setup_native.sh     One-time install (Ubuntu 24.04).
start_sim.sh        Start the simulator.  ← the one you'll use
test_ros.sh         Run the ROS 2 drive test against a running sim.

sim/
  launch_blueboat.sh      brings up Gazebo + SITL + bridge + MAVROS + QGC
  blueboat_waves_lite.sdf the default world (boat + hydrodynamics)
  blueboat_waves.sdf      the full wave world
  blueboat.parm           ArduPilot parameters
  blueboat_mission.txt    sample 25 m rectangular search pattern
  bridge.yaml             ros_gz_bridge topic mapping
  fastdds_udp.xml         DDS over UDP only
  launch/                 ROS 2 launch files (bridge, clock throttle, MAVROS)

tests/              test_boat_drive.py, the automated drive test
docs/               Guides and build history

run_sim.sh          Docker launcher (alternative, see below)
build_sim.sh        Build the Docker image from source
Dockerfile.sim      The Docker image definition
```

---

## Docker (alternative)

The same stack is also packaged as a Docker image (`jenbensen17/y_boat_sim`), mainly
for machines that can't run Ubuntu 24.04 natively, such as macOS:

```bash
./run_sim.sh          # pulls the image if needed, detects OS/GPU/display
./test_ros.sh         # in a second terminal
```

It's less reliable than the native install: the Gazebo window depends on GPU and
display passthrough into the container, which varies by machine. On macOS Docker has no
GPU access at all, so Gazebo renders on the CPU there. Don't run the Docker and native
sims at the same time; they use the same ports.

---

## Documentation

| Guide | Read it when |
|---|---|
| [docs/ros2-development.md](docs/ros2-development.md) | You're writing ROS 2 nodes or Nav2 against the sim. **Start here.** |
| [docs/y_boat_core-integration.md](docs/y_boat_core-integration.md) | You want your `y_boat_core` autonomy stack driving this boat. |
| [docs/platforms.md](docs/platforms.md) | Platform-specific setup notes. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Something didn't come up. |
| [docs/](docs/README.md) | Build history and step reports. |

---

## Why We Use These Three Core Tools

| Tool | Role | Why We Chose It | How It Helps Us |
|---|---|---|---|
| **Gazebo Harmonic** | **Virtual Lake** *(Physics & World)* | Accurate fluid dynamics, water buoyancy, wave interaction (`asv_wave_sim`), and thruster response. | Replaces the physical lake. Allows testing collision avoidance, rough water stability, and thruster limits with zero risk to hardware. |
| **ArduPilot SITL + Terminal** | **Autopilot Brain** *(Low-Level Control)* | Line-for-line identical firmware (`Rover-4.7.1`) to the real boat's Pixhawk/Cube computer. Battle-tested EKF3 state estimation and skid-steer thruster mixing. | Any ROS 2 autonomy code that works in SITL works on the physical boat with zero firmware changes. The terminal gives engineers instant access to change modes (`mode GUIDED`), arm thrusters, and tune 1,000+ parameters live. |
| **QGroundControl (QGC)** | **Shore Station** *(Operator Mission Control)* | Global standard ground control station communicating over MAVLink (UDP 14550). Rich satellite map, HUD, battery voltage, and waypoint planner. | Gives human operators complete situational awareness. Allows drawing and uploading autonomous GPS waypoint routes for competition tasks, plus instant safety overrides (Return-to-Launch or manual joystick takeover). |
