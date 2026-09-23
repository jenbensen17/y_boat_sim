# BlueBoat Autonomous Surface Vessel (ASV) Simulator

[![ROS 2 Jazzy](https://img.shields.io/badge/ROS_2-Jazzy-blue.svg)](https://docs.ros.org/en/jazzy/)
[![Gazebo Harmonic](https://img.shields.io/badge/Gazebo-Harmonic-orange.svg)](https://gazebosim.org/docs/harmonic)
[![ArduPilot Rover](https://img.shields.io/badge/ArduPilot-Rover--4.7.1-green.svg)](https://ardupilot.org/rover/)
[![License](https://img.shields.io/badge/License-MIT-purple.svg)](LICENSE)

The official standalone simulation environment for the **BYU Robotics Association RoboBoat Team**. This repository provides a complete, hardware-in-the-loop-equivalent software simulator for the BlueBoat autonomous surface vessel.

It packages **Gazebo Harmonic**, **ArduPilot SITL (`Rover-4.7.1`)**, **`asv_wave_sim` hydrodynamics**, **`ros_gz_bridge`**, **MAVROS**, and **QGroundControl** into a reproducible Docker container that runs out of the box on **Linux**, **Windows (WSL2)**, and **macOS**.

---

## Table of Contents
- [Architecture & System Flow](#architecture--system-flow)
- [Prerequisites by Operating System](#prerequisites-by-operating-system)
  - [Linux (Ubuntu / Arch / Fedora)](#1-linux-native)
  - [Windows 10/11 (WSL2)](#2-windows-1011-wsl2)
  - [macOS (Apple Silicon & Intel)](#3-macos-apple-silicon-m1m4--intel)
- [Step-by-Step Quickstart](#step-by-step-quickstart)
  - [1. Clone the Repository](#step-1-clone-the-repository)
  - [2. Build the Simulation Image](#step-2-build-the-simulation-image)
  - [3. Launch the Simulator](#step-3-launch-the-simulator)
  - [4. Verify ROS 2 Vehicle Control](#step-4-verify-ros-2-vehicle-control)
- [Developing ROS 2 Nodes & Nav2](#developing-ros-2-nodes--nav2)
  - [Entering the Container](#entering-the-container)
  - [Key Topics & Services Reference](#key-topics--services-reference)
  - [Four Critical Rules for Autonomy & Nav2](#four-critical-rules-for-autonomy--nav2)
  - [Minimal Python Control Example](#minimal-python-control-example)
- [Platform-Specific Guides](#platform-specific-guides)
  - [Windows WSL2 Setup Details](#windows-wsl2-setup-details)
  - [macOS Workflows (Native QGC vs XQuartz)](#macos-workflows)
  - [Headless / Cloud / CI Mode](#headless--cloud--ci-mode)
- [Common Commands & Cheat Sheet](#common-commands--cheat-sheet)
- [Troubleshooting & FAQs](#troubleshooting--faqs)

---

## Architecture & System Flow

```mermaid
flowchart TD
    subgraph Host ["Host OS (Linux / Windows WSL2 / macOS)"]
        UserShell["Host Shell / Terminal"] -->|./run_sim.sh| DockerDaemon["Docker Engine"]
    end

    subgraph Container ["Docker Container (y_boat_sim)"]
        GZ["Gazebo Harmonic<br/>(blueboat_waves.sdf)"]
        SITL["ArduPilot Rover SITL<br/>(Rover-4.7.1 skid-steer)"]
        Bridge["ros_gz_bridge<br/>(/clock, /sim/ground_truth/odom)"]
        MAVROS["MAVROS Node<br/>(udp://127.0.0.1:14551@)"]
        QGC["QGroundControl<br/>(UDP 14550)"]

        GZ <-->|JSON plugin :9002/:9003| SITL
        GZ -->|gz.msgs.Clock| Bridge
        Bridge -->|ROS 2 /clock| MAVROS
        SITL -->|MAVLink UDP :14550| QGC
        SITL -->|MAVLink UDP :14551| MAVROS
    end

    subgraph Desktop ["Desktop GUI (Exactly 3 Windows)"]
        GZ -.->|Render 3D World| Win1["1. Gazebo Sim GUI"]
        QGC -.->|Render Map & Status| Win2["2. QGroundControl GUI"]
        SITL -.->|xterm with MAVProxy CLI| Win3: ["3. ArduPilot Terminal"]
    end

    subgraph Autonomy ["Autonomous Software Stack"]
        MAVROS <-->|ROS 2 Topics & Services| UserNodes["Your ROS 2 Nodes / Nav2"]
    end
```

---

## Prerequisites by Operating System

### 1. Linux (Native)
- **Docker**: Docker Engine 24.0+ (`sudo apt install docker.io` or official Docker repository).
- **Docker Permissions**: Ensure your user is in the docker group: `sudo usermod -aG docker $USER` (log out and back in).
- **GPU Driver**:
  - *NVIDIA*: Install NVIDIA drivers and `nvidia-container-toolkit` (`sudo apt install nvidia-container-toolkit`).
  - *Intel / AMD*: Works out of the box via `/dev/dri`.
  - *No GPU*: Falls back automatically to CPU software rendering.

### 2. Windows 10/11 (WSL2)
- **WSL2 with WSLg** (standard on Windows 11 and updated Windows 10). Run `wsl --update` from PowerShell if needed.
- **NVIDIA GPU Driver for Windows**: Install the regular Windows NVIDIA driver from nvidia.com. *Do not install Linux display drivers inside WSL2* (Windows forwards GPU acceleration automatically via DirectX `/dev/dxg`).
- **Docker Desktop for Windows**:
  1. Open Docker Desktop **Settings -> General** $\rightarrow$ verify *"Use the WSL 2 based engine"* is checked.
  2. Open **Settings -> Resources -> WSL Integration** $\rightarrow$ turn on integration for your Ubuntu/Linux distro.

### 3. macOS (Apple Silicon M1–M4 & Intel)
- **Docker Desktop for Mac**: Installed and running.
- **Apple Silicon (M1/M2/M3/M4)**: In Docker Desktop **Settings -> General**, ensure *"Use Rosetta for x86/amd64 emulation on Apple Silicon"* is checked.
- **Optional Native GCS**: Download [QGroundControl v5.1.4 for macOS (.dmg)](https://github.com/mavlink/qgroundcontrol/releases/download/v5.1.4/QGroundControl.dmg).

---

## Step-by-Step Quickstart

### Step 1: Clone the Repository
Open a terminal (in WSL, open your Ubuntu shell) and clone into your Linux home directory:

```bash
git clone <your-sim-repo-url> ~/y_sim
cd ~/y_sim
```

> [!IMPORTANT]
> **Windows WSL Users**: Always clone the repository inside the Linux filesystem (e.g. `~/y_sim`), **never** inside the Windows mount (`/mnt/c/...`). The `/mnt/c` drive has much slower file I/O and does not support Linux file sockets or POSIX permissions.

---

### Step 2: Obtain the Simulation Image (3 Ways)

Choose the method that fits your situation:

#### Option A: Pull Prebuilt from Docker Hub (Fastest, ~1–2 minutes) — *Recommended for Teammates*
Instead of burning 15–20 minutes compiling ArduPilot and Gazebo plugins from source on every laptop, pull the official prebuilt image:

```bash
docker pull jenbensen17/y_boat_sim:latest
docker tag jenbensen17/y_boat_sim:latest y_boat_sim_scratch:1c
```
*(Or simply run `./run_sim.sh` — if the image isn't local, it will automatically pull it from Docker Hub and tag it for you!)*

#### Option B: Offline USB / Lab Share (~1 minute) — *Best in Person*
If you are in the robotics lab with someone who already has the image:
1. On the machine with the image:
   ```bash
   docker save yrobotics/y_boat_sim:latest | gzip > y_boat_sim.tar.gz
   ```
2. Copy `y_boat_sim.tar.gz` to a USB drive and plug it into your laptop.
3. Load the image without internet or building:
   ```bash
   docker load < y_boat_sim.tar.gz
   ```

#### Option C: Build Locally from Source (~5–7 minutes)
If you are developing Dockerfile customizations or building completely from scratch:

```bash
./build_sim.sh
```
*(The Dockerfile is optimized with shallow git clones, BuildKit parallelization, and skips wxPython source compilation, cutting build time from 20 minutes down to ~5–7 minutes. On Apple Silicon Macs, `--platform linux/amd64` is enforced automatically).*

---

### Step 3: Launch the Simulator
Start the entire simulation stack with a single command:

```bash
./run_sim.sh
```

#### What opens automatically:
Exactly **3 graphical windows** will appear on your desktop:
1. **Gazebo Sim GUI**: 3D visual simulation showing the BlueBoat floating in calm water.
2. **QGroundControl**: Ground station displaying live vehicle telemetry, battery status, satellite lock, and the vehicle on the map.
3. **ArduPilot Terminal (`xterm`)**: An interactive MAVProxy console (`MANUAL> ` prompt) connected to the simulated autopilot. You can type commands directly here (e.g., `mode GUIDED`, `arm throttle`, `param show`).

The terminal where you ran `./run_sim.sh` supervises the container. Press **`Ctrl+C`** in that terminal at any time to cleanly shut down all simulator processes and release ports.

> [!TIP]
> **Gazebo 3D lagging on Windows WSL2 or laptops?**
> You can disable Gazebo's heavy 3D window while **keeping QGroundControl and ArduPilot terminal active**:
> ```bash
> ./run_sim.sh --no-gz-gui
> ```
> Gazebo's physics and hydrodynamics run headless at full 1000 Hz with almost zero CPU/GPU overhead, while QGroundControl (2D map & telemetry) and the terminal run smoothly at 60 FPS.

---

### Step 4: Verify ROS 2 Vehicle Control
Leave the simulator running, open a **new terminal tab**, and execute:

```bash
./test_ros.sh
```

#### What this test performs:
1. Verifies MAVROS heartbeat and connectivity to the autopilot.
2. Sets flight mode to `GUIDED` via the `/mavros/set_mode` service.
3. Arms the vehicle thrusters via `/mavros/cmd/arming` (with automatic pre-arm settling retries).
4. Streams forward body-frame velocity (`1.5 m/s`) for 8 seconds.
5. Displays real-time odometry updates and total distance traveled.
6. Halts the boat and disarms it cleanly.

```
=================================================================
                   TEST SUMMARY & RESULTS
=================================================================
  Starting Position: (  0.00,   0.30)
  Ending Position:   ( -0.01,  13.32)
  Total Distance:     13.02 meters
  Final Heading:       90.1°

[SUCCESS] The boat successfully armed, drove forward, and updated odometry!
          You should have seen the boat move in Gazebo and QGroundControl.
=================================================================
```

---

## Developing ROS 2 Nodes & Nav2

### Entering the Container
To run ROS 2 CLI tools (`ros2 topic`, `ros2 service`, `ros2 node`) or run your custom nodes against the live simulation:

```bash
docker exec -it y_boat_sim bash
```

Inside the container, ROS 2 Jazzy environment variables are pre-sourced.

---

### Key Topics & Services Reference

| Topic / Service | Interface Type | Purpose / Description |
|---|---|---|
| `/clock` | `rosgraph_msgs/msg/Clock` | Simulation clock (~940 Hz). All nodes **must** use `use_sim_time:=True`. |
| `/mavros/state` | `mavros_msgs/msg/State` | Autopilot state: `connected`, `armed`, and `mode`. |
| `/mavros/local_position/odom` | `nav_msgs/msg/Odometry` | EKF estimated position and velocity. |
| `/sim/ground_truth/odom` | `nav_msgs/msg/Odometry` | Simulator ground truth (for debugging / benchmarking). |
| `/mavros/setpoint_raw/local` | `mavros_msgs/msg/PositionTarget` | **Primary velocity control target for Nav2** (see details below). |
| `/mavros/set_mode` | `mavros_msgs/srv/SetMode` | Set vehicle flight mode (e.g. `custom_mode: 'GUIDED'`). |
| `/mavros/cmd/arming` | `mavros_msgs/srv/CommandBool` | Arm or disarm vehicle thrusters (`value: true` or `false`). |

---

### Four Critical Rules for Autonomy & Nav2

#### 1. Velocity Control Frame (Body Frame vs. Local ENU)
- **Do NOT publish velocity to `/mavros/setpoint_velocity/cmd_vel_unstamped`** — MAVROS interprets that topic in the fixed **Local ENU** frame (the boat will travel north/east regardless of where its bow is pointed).
- **Use `/mavros/setpoint_raw/local`** with `mavros_msgs/msg/PositionTarget`:
  - `coordinate_frame = 8` (`FRAME_BODY_NED`).
  - `type_mask = 1479` (ignores position, acceleration, and yaw; keeps `velocity` + `yaw_rate`).
  - `velocity.x` = Forward speed in m/s (body frame).
  - `yaw_rate` = Turning rate in rad/s.

#### 2. The 3-Second Guided Timeout
ArduPilot Rover has a hardcoded **3000 ms** timeout on guided velocity targets. If no setpoint is received within 3 seconds, ArduPilot automatically halts the boat.
- Any controller or Nav2 bridge **must publish setpoints continuously at $\ge 10\text{ Hz}$**.
- When the boat should remain stationary in GUIDED mode, stream zero-velocity setpoints (`vx=0.0, yaw_rate=0.0`) as keepalives.

#### 3. Simulation Clock Synchronization
The simulator publishes `/clock` straight from Gazebo's physics engine.
- Every ROS 2 node, launch file, and Nav2 instance must run with:
  ```python
  parameters=[{'use_sim_time': True}]
  ```

#### 4. TF Transform Tree
- MAVROS publishes static transforms (`map_ned`, `odom_ned`, `base_link_frd`), but does not publish dynamic transforms (`map -> odom -> base_link`).
- Before launching Nav2, either enable MAVROS dynamic TF or run a node that broadcasts `odom -> base_link` from `/mavros/local_position/odom`.

---

### Minimal Python Control Example

```python
import rclpy
from rclpy.node import Node
from mavros_msgs.msg import PositionTarget

class BoatVelocityPublisher(Node):
    def __init__(self):
        super().__init__('boat_vel_publisher')
        self.pub = self.create_publisher(PositionTarget, '/mavros/setpoint_raw/local', 10)
        self.timer = self.create_timer(0.1, self.send_cmd) # 10 Hz stream

    def send_cmd(self):
        msg = PositionTarget()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.coordinate_frame = PositionTarget.FRAME_BODY_NED # 8
        # Mask out position, acceleration, and yaw (keep velocity.x and yaw_rate)
        msg.type_mask = (PositionTarget.IGNORE_PX | PositionTarget.IGNORE_PY | PositionTarget.IGNORE_PZ |
                         PositionTarget.IGNORE_AFX | PositionTarget.IGNORE_AFY | PositionTarget.IGNORE_AFZ |
                         PositionTarget.IGNORE_YAW)
        msg.velocity.x = 1.5   # 1.5 m/s forward
        msg.yaw_rate = 0.0     # 0.0 rad/s
        self.pub.publish(msg)

def main():
    rclpy.init()
    node = BoatVelocityPublisher()
    rclpy.spin(node)
    rclpy.shutdown()

if __name__ == '__main__':
    main()
```

---

## Platform-Specific Guides

### Windows WSL2 Setup Details
1. **WSLg (GUI)**: Windows 11 and updated Windows 10 include WSLg, which automatically renders X11 and Wayland windows directly on the Windows desktop with hardware acceleration.
2. **GPU Acceleration**: The launcher automatically detects `/dev/dxg` and passes it to Docker. DirectX 12 hardware acceleration is enabled without any configuration.
3. **Troubleshooting WSLg Display**: If windows do not appear, open PowerShell and update WSL:
   ```powershell
   wsl --update
   wsl --shutdown
   ```
   Then reopen your WSL terminal and relaunch `./run_sim.sh`.

---

### macOS Workflows

#### Workflow 1: Headless Sim + Native macOS QGroundControl *(Recommended for Mac)*
This gives the fastest performance and full Apple Metal 60 FPS GPU rendering on Retina displays:
1. Start the simulation in headless mode:
   ```bash
   HEADLESS=1 ./run_sim.sh
   ```
2. Download [QGroundControl v5.1.4 for macOS (.dmg)](https://github.com/mavlink/qgroundcontrol/releases/download/v5.1.4/QGroundControl.dmg), install it to `/Applications`, and open it. It auto-connects to the simulator on `127.0.0.1:14550`.
3. In a second terminal, verify with `./test_ros.sh`.

#### Workflow 2: Full 3-Window GUI via XQuartz
To see the 3D Gazebo window on macOS:
1. Install XQuartz: `brew install --cask xquartz`.
2. Open XQuartz $\rightarrow$ **Settings -> Security** $\rightarrow$ check **"Allow connections from network clients"**.
3. In Mac terminal: `xhost + 127.0.0.1`.
4. Run `./run_sim.sh`. The launcher routes display traffic to `host.docker.internal:0` automatically.

---

### Headless / Cloud / CI Mode
If running on a remote cloud server (AWS, GCP), via SSH without X11 forwarding, or in a GitHub Actions runner:

```bash
HEADLESS=1 ./run_sim.sh
```

The script automatically detects an empty `$DISPLAY` environment variable and falls back to headless mode. Gazebo physics, ArduPilot SITL, and all ROS 2 topics run at full speed.

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

---

## Troubleshooting & FAQs

### 1. "Port 5760 / 5762 / 5763 already in use"
**Cause**: A previous SITL process was not killed cleanly and is still bound to the port.  
**Fix**: Stop any existing simulator container and kill remaining background processes:
```bash
docker stop y_boat_sim 2>/dev/null || true
pkill -f ardurover 2>/dev/null || true
```

### 2. "Permission denied while trying to connect to the Docker daemon"
**Cause**: Your user account does not have permission to access `/var/run/docker.sock`.  
**Fix**: Add your user to the `docker` group:
```bash
sudo usermod -aG docker $USER
```
Log out and log back in, or restart your terminal.

### 3. "Simulation container 'y_boat_sim' is not running!"
**Cause**: You ran `./test_ros.sh` before starting `./run_sim.sh`.  
**Fix**: Open one terminal and start `./run_sim.sh`. Once the simulator logs `Simulator is READY!`, open a second terminal and run `./test_ros.sh`.

### 4. "Boat does not move when sending velocity"
**Cause**: 
- Mode was not changed to `GUIDED` (check `/mavros/state`).
- Vehicle was not armed (call `/mavros/cmd/arming`).
- Velocity was sent to `cmd_vel_unstamped` (in local ENU) instead of `/mavros/setpoint_raw/local` (in body frame).
- Velocity stream rate was too slow (< 3 Hz), causing the 3-second guided timeout to stop the vehicle. Ensure you stream setpoints at $\ge 10\text{ Hz}$.

### 5. "Simulation image 'y_boat_sim_scratch:1c' is not present locally"
**Cause**: You pulled the image under a remote name (e.g. `jenbensen17/y_boat_sim:latest`) and the local alias `y_boat_sim_scratch:1c` does not exist yet.  
**Fix**: Tag the pulled image as the local simulation tag:
```bash
docker tag jenbensen17/y_boat_sim:latest y_boat_sim_scratch:1c
./run_sim.sh
```
*(Or specify the image explicitly: `IMAGE=jenbensen17/y_boat_sim:latest ./run_sim.sh`)*

### 6. Windows WSL2: "Cannot open display" or Blank Window
**Cause**: `$DISPLAY` is empty in your current WSL2 shell session, or WSLg is not updated.  
**Fix**:
1. Check your display variable:
   ```bash
   echo $DISPLAY
   ```
   If it is blank, set it and add to your `~/.bashrc`:
   ```bash
   export DISPLAY=:0
   echo 'export DISPLAY=:0' >> ~/.bashrc
   ```
2. Update WSL from an Administrator PowerShell prompt on Windows:
   ```powershell
   wsl --update
   ```
3. Test that the container starts in headless mode:
   ```bash
   HEADLESS=1 ./run_sim.sh
   ```
