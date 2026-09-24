# Connecting with y_boat_core: Live Simulation & Sim-to-Real Parity

A common question is: *How does code running inside `y_boat_core` (`boat_dev`) communicate with and update `y_sim` (`y_boat_sim`)?*

The two containers do not copy or touch each other's files. Instead, they run side-by-side on your host machine and communicate live across the **ROS 2 network via DDS (Data Distribution Service)**, functioning exactly like two physical computers connected over an Ethernet switch.

## Network Architecture & DDS Data Flow

Both containers are configured with `network_mode: host` and `ROS_DOMAIN_ID=10`. This allows ROS 2 Jazzy DDS discovery to find topics automatically across container boundaries:

```text
 ┌──────────────────────────────────────┐             ┌──────────────────────────────────────┐
 │       Container 1: boat_dev          │             │       Container 2: y_boat_sim        │
 │            (y_boat_core)             │             │               (y_sim)                │
 │                                      │             │                                      │
 │  Your Autonomy / Navigation Nodes    │             │  Gazebo + ArduPilot SITL + MAVROS    │
 │                                      │   ROS 2     │                                      │
 │  Listens to:                         │   DDS       │  Publishes:                          │
 │    • /mavros/local_position/odom     │◄────────────│    • Simulated GPS & IMU Odometry    │
 │    • /mavros/state (armed / mode)    │◄────────────│    • Autopilot status                │
 │    • /clock (simulated time)         │◄────────────│    • Physics clock                   │
 │                                      │             │                                      │
 │  Publishes:                          │             │  Acts on:                            │
 │    • /mavros/setpoint_raw/local      │────────────►│    • Controls thrusters & boat moves │
 │    • /mavros/setpoint_position/local │────────────►│    • Navigates to target position    │
 └──────────────────────────────────────┘             └──────────────────────────────────────┘
                                                                         │
                                                                         ▼
                                                       Live in Gazebo & QGroundControl:
                                                       You see the boat drive on screen!
```

## Standard Development Workflow

1. **Terminal 1 — Launch the Simulator**:
   ```bash
   cd ~/y_sim
   ./run_sim.sh
   # (or ./run_sim.sh --no-gz-gui for headless physics with GUI QGC)
   ```
   *Gazebo, QGroundControl, and ArduPilot SITL start and broadcast telemetry on `ROS_DOMAIN_ID=10`.*

2. **Terminal 2 — Start the Autonomy Dev Container**:
   ```bash
   cd ~/y_boat/y_boat_core
   ./scripts/run.sh
   docker exec -it boat_dev bash
   ```

3. **Inside `boat_dev` — Build and Run Your Autonomy Stack**:
   ```bash
   ros2 run my_navigation_pkg waypoint_follower
   ```
   - As your node calculates commands and publishes velocity or position setpoints, the boat in **`y_sim` immediately responds and drives through the water**.
   - QGroundControl and Gazebo reflect the boat's movements, thruster plumes, and GPS track in real time.

## The Big Architectural Benefit: "Sim-to-Real" Parity

This strict separation between the vehicle simulation (`y_sim`) and the autonomy stack (`y_boat_core`) gives the team complete **Sim-to-Real Parity**:

| Environment | Autonomy Stack | Hardware / Simulation Backend | MAVROS Interface |
|---|---|---|---|
| **Simulation (Lab / Laptop)** | `boat_dev` (`y_boat_core`) | Gazebo Harmonic + ArduPilot SITL (`y_sim`) | Same `/mavros/...` topics |
| **Real Lake (Physical Vessel)** | `boat_dev` (on Jetson Nano) | Physical BlueBoat Pixhawk 6C Autopilot | Same `/mavros/...` topics |

Because both the simulation and the real vessel expose the identical MAVROS ROS 2 API and coordinate frames, **your autonomy, perception, and Nav2 software runs on the real boat with zero code changes**.

---
