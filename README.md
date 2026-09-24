# BlueBoat Autonomous Surface Vessel (ASV) Simulator

[![ROS 2 Jazzy](https://img.shields.io/badge/ROS_2-Jazzy-blue.svg)](https://docs.ros.org/en/jazzy/)
[![Gazebo Harmonic](https://img.shields.io/badge/Gazebo-Harmonic-orange.svg)](https://gazebosim.org/docs/harmonic)
[![ArduPilot Rover](https://img.shields.io/badge/ArduPilot-Rover--4.7.1-green.svg)](https://ardupilot.org/rover/)

The official standalone simulation environment for the **BYU Robotics Association RoboBoat Team**. This repository provides a complete, hardware-in-the-loop-equivalent software simulator for the BlueBoat autonomous surface vessel.

It packages **Gazebo Harmonic**, **ArduPilot SITL (`Rover-4.7.1`)**, **`asv_wave_sim` hydrodynamics**, **`ros_gz_bridge`**, **MAVROS**, and **QGroundControl** into a reproducible Docker container that runs out of the box on **Linux**, **Windows (WSL2)**, and **macOS**.

---

## Quickstart

Three commands. The launcher pulls the image if you don't have it, and detects your
OS, GPU and display on its own.

```bash
git clone git@github.com:jenbensen17/y_boat_sim.git ~/y_sim
cd ~/y_sim
./run_sim.sh
```

Then, in a second terminal, verify that ROS 2 can drive the boat:

```bash
./test_ros.sh
```

That's it. Press `Ctrl+C` in the first terminal to shut everything down cleanly.

> [!IMPORTANT]
> **Windows/WSL users**: clone inside the Linux filesystem (`~/y_sim`), **never**
> under `/mnt/c/...`. See [docs/platforms.md](docs/platforms.md) for per-OS
> prerequisites.

### What opens

Three windows appear on your desktop:

1. **Gazebo Sim** — the 3D boat floating in water.
2. **QGroundControl** — telemetry, map and the waypoint planner.
3. **ArduPilot terminal** (`xterm`) — a live MAVProxy console at a `MANUAL>` prompt.

> [!TIP]
> If the Gazebo 3D window is slow on a laptop or under WSL2, run
> `./run_sim.sh --no-gz-gui`. Physics keeps running at full rate; you keep QGC and
> the terminal.

---

## Repository Layout

Everything at the top level is something **you run on your machine**. Everything in
`sim/` runs **inside the container** and you rarely need to touch it.

```
run_sim.sh          Start the simulator.  ← the one you'll use
build_sim.sh        Build the Docker image from source (optional; run_sim.sh pulls it).
test_ros.sh         Run the ROS 2 verification test against a running sim.
Dockerfile.sim      The image definition.

sim/                Runs inside the container:
  launch_blueboat.sh  brings up Gazebo + SITL + bridge + MAVROS + QGC
  blueboat_waves.sdf  the world (boat + hydrodynamics)
  blueboat.parm       ArduPilot parameters
  blueboat_mission.txt  sample 25 m rectangular search pattern
  bridge.yaml         ros_gz_bridge topic mapping
  fastdds_udp.xml     forces DDS onto UDP so topics cross container boundaries
  launch/             ROS 2 launch files (bridge, MAVROS)

tests/              test_boat_drive.py — the automated drive test
docs/               Guides and build history
```

---

## Documentation

| Guide | Read it when |
|---|---|
| [docs/ros2-development.md](docs/ros2-development.md) | You're writing ROS 2 nodes or Nav2 against the sim. **Start here.** |
| [docs/y_boat_core-integration.md](docs/y_boat_core-integration.md) | You want your `y_boat_core` autonomy stack driving this boat. |
| [docs/platforms.md](docs/platforms.md) | Setting up Linux, Windows/WSL2 or macOS; or running headless/CI. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Something didn't come up. |
| [docs/](docs/README.md) | Build history and step reports. |

---

## Why We Use These Three Core Tools

| Tool | Role | Why We Chose It | How It Helps Us |
|---|---|---|---|
| **Gazebo Harmonic** | **Virtual Lake** *(Physics & World)* | Accurate fluid dynamics, water buoyancy, wave interaction (`asv_wave_sim`), and thruster response. | Replaces the physical lake. Allows testing collision avoidance, rough water stability, and thruster limits with zero risk to hardware. |
| **ArduPilot SITL + Terminal** | **Autopilot Brain** *(Low-Level Control)* | Line-for-line identical firmware (`Rover-4.7.1`) to the real boat's Pixhawk/Cube computer. Battle-tested EKF3 state estimation and skid-steer thruster mixing. | Any ROS 2 autonomy code that works in SITL works on the physical boat with zero firmware changes. The terminal gives engineers instant access to change modes (`mode GUIDED`), arm thrusters, and tune 1,000+ parameters live. |
| **QGroundControl (QGC)** | **Shore Station** *(Operator Mission Control)* | Global standard ground control station communicating over MAVLink (UDP 14550). Rich satellite map, HUD, battery voltage, and waypoint planner. | Gives human operators complete situational awareness. Allows drawing and uploading autonomous GPS waypoint routes for competition tasks, plus instant safety overrides (Return-to-Launch or manual joystick takeover). |

---

## Common Commands & Cheat Sheet

```bash
# Build the simulation Docker image
./build_sim.sh

# Launch full simulation (Gazebo + QGC + ArduPilot terminal)
./run_sim.sh

# Launch with Gazebo headless (fastest physics, no 3D lag), keeping QGC & xterm
./run_sim.sh --no-gz-gui

# Launch without QGroundControl
QGC=0 ./run_sim.sh

# Launch in headless mode (no GUI windows)
HEADLESS=1 ./run_sim.sh

# Run the automated ROS 2 drive test
./test_ros.sh

# Open interactive bash shell inside running container
docker exec -it y_boat_sim bash

# Stop the simulation container from another terminal
docker stop y_boat_sim
```