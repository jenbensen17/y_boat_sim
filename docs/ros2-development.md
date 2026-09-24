# Developing ROS 2 Nodes & Nav2

## Entering the Container
To run ROS 2 CLI tools (`ros2 topic`, `ros2 service`, `ros2 node`) or run your custom nodes against the live simulation:

```bash
docker exec -it y_boat_sim bash
```

Inside the container, ROS 2 Jazzy environment variables are pre-sourced.

---

## Key Topics & Services Reference

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

## Four Critical Rules for Autonomy & Nav2

### 1. Velocity Control Frame (Body Frame vs. Local ENU)
- **Do NOT publish velocity to `/mavros/setpoint_velocity/cmd_vel_unstamped`** — MAVROS interprets that topic in the fixed **Local ENU** frame (the boat will travel north/east regardless of where its bow is pointed).
- **Use `/mavros/setpoint_raw/local`** with `mavros_msgs/msg/PositionTarget`:
  - `coordinate_frame = 8` (`FRAME_BODY_NED`).
  - `type_mask = 1479` (ignores position, acceleration, and yaw; keeps `velocity` + `yaw_rate`).
  - `velocity.x` = Forward speed in m/s (body frame).
  - `yaw_rate` = Turning rate in rad/s.

### 2. The 3-Second Guided Timeout
ArduPilot Rover has a hardcoded **3000 ms** timeout on guided velocity targets. If no setpoint is received within 3 seconds, ArduPilot automatically halts the boat.
- Any controller or Nav2 bridge **must publish setpoints continuously at $\ge 10\text{ Hz}$**.
- When the boat should remain stationary in GUIDED mode, stream zero-velocity setpoints (`vx=0.0, yaw_rate=0.0`) as keepalives.

### 3. Simulation Clock Synchronization
The simulator publishes `/clock` straight from Gazebo's physics engine.
- Every ROS 2 node, launch file, and Nav2 instance must run with:
  ```python
  parameters=[{'use_sim_time': True}]
  ```

### 4. TF Transform Tree
- MAVROS publishes static transforms (`map_ned`, `odom_ned`, `base_link_frd`), but does not publish dynamic transforms (`map -> odom -> base_link`).
- Before launching Nav2, either enable MAVROS dynamic TF or run a node that broadcasts `odom -> base_link` from `/mavros/local_position/odom`.

---

## Minimal Python Control Example

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

## Giving Waypoint Missions (3 Methods)

There are three ways to command waypoint missions on the BlueBoat:

### Method 1: The Visual Way in QGroundControl (Recommended for Testing & Demos)
1. **Open Plan Screen**: Click the **Plan** icon (paper & pencil icon, top-left).
2. **Create or Load Waypoints**:
   - *Manual*: Click **Waypoint** on the left menu, then click anywhere on the lake map to drop points (WP 1, WP 2, WP 3...). On the right panel, configure vessel speed (e.g. `1.5 m/s`).
   - *Sample Mission File*: Click **File** $\rightarrow$ **Open** and select [`sim/blueboat_mission.txt`](../sim/blueboat_mission.txt) (a pre-configured 25-meter rectangular search pattern on the lake).
3. **Upload to the Boat**: Click the **Upload** button (yellow upward arrow, top-right). This transmits the mission over MAVLink directly into ArduPilot SITL's memory.
4. **Execute the Mission**: Switch back to the **Fly / Drive View** (paper airplane icon) and slide the bottom confirmation bar: **Slide to Start Mission** (or switch Mode to `AUTO`). The boat will autonomously arm and follow the path!

### Method 2: The Fast Way in the ArduPilot Terminal (MAVProxy CLI)
Inside the `xterm` ArduPilot SITL terminal:
```text
MANUAL> wp load /home/simuser/sim_scratch/sim/blueboat_mission.txt
Loaded 5 waypoints from blueboat_mission.txt

MANUAL> mode AUTO
AUTO> arm throttle
```
- `wp list` — view coordinates of all stored waypoints.
- `wp clear` — erase all waypoints from flight controller memory.
- `mode MANUAL` / `mode RTL` — disengage mission or return to home launch position.

### Method 3: Programmatically via ROS 2
- **Dynamic Setpoints in `GUIDED` Mode**: Publish `geometry_msgs/msg/PoseStamped` coordinates directly to `/mavros/setpoint_position/local`.
- **Upload Waypoint List**: Use the MAVROS service `/mavros/mission/push` (`mavros_msgs/srv/WaypointPush`), then call `/mavros/set_mode` with `custom_mode='AUTO'`.

---

---

Next: [Connecting with y_boat_core](y_boat_core-integration.md).
