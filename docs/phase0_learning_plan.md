# Phase 0 Implementation & Learning Plan — Nav2 Foundations

## 1. Goal Description
Build the foundational ROS 2 navigation plumbing required before Nav2 can control the BlueBoat in simulation:
1. **Dynamic TF Chain (`map -> odom -> base_link`)**: Nav2 requires a continuous coordinate transformation tree. MAVROS provides only static aliases (`map -> map_ned`, etc.). We will broadcast `odom -> base_link` from `/mavros/local_position/odom` and latch `map -> odom` as a static identity.
2. **Body-Frame `cmd_vel` Velocity Bridge**: Translate Nav2's `/cmd_vel` (`geometry_msgs/Twist`) into `/mavros/setpoint_raw/local` (`mavros_msgs/PositionTarget`) with `FRAME_BODY_NED`. Stream continuously at 10 Hz (with zero-velocity keepalives) to defeat ArduPilot's hardcoded 3.0s guided-mode failsafe.
3. **Telemetry Rate Bump**: Boost `/mavros/local_position/odom` from ~3.7 Hz to 20 Hz using `/mavros/set_message_interval` so Nav2's local controller has sufficient bandwidth.
4. **Milestone Proof**: Drive the boat interactively via `teleop_twist_keyboard` and inspect the live TF tree in `rviz2` (both running from `y_boat_sim` across the shared DDS graph).

> [!IMPORTANT]
> **Learning Mode Hard Constraint**: The user writes all node logic. The assistant provides commented skeletons, architectural explanations, code reviews, and debugging guidance.

---

## 2. Environment Architecture & Constraints

```mermaid
graph TD
    Nav2["Nav2 / teleop_twist_keyboard<br/>(/cmd_vel: geometry_msgs/Twist)"] -->|10 Hz Twist| Bridge["cmd_vel_bridge Node<br/>(boat_nav in boat_dev)"]
    Bridge -->|10 Hz PositionTarget<br/>FRAME_BODY_NED| MAVROS["MAVROS /mavros/setpoint_raw/local<br/>(in y_boat_sim)"]
    MAVROS -->|MAVLink SET_POSITION_TARGET_LOCAL_NED| ArduPilot["ArduPilot Rover (GUIDED mode)"]
    ArduPilot --> Thrusters["BlueBoat Thrusters (Gazebo)"]
    
    ArduPilot -->|MAVLink EKF Position| MAVROS
    MAVROS -->|/mavros/local_position/odom<br/>frame_id: map| TFNode["boat_tf_publisher Node<br/>(boat_nav in boat_dev)"]
    TFNode -->|/tf: odom -> base_link| TFGraph["TF Tree"]
    TFNode -->|/tf_static: map -> odom (identity)| TFGraph
```

### Key Technical Realities Verified Live
1. **Zero Dockerfile Changes Required**:
   - `teleop_twist_keyboard` and `rviz2` are already installed and display-ready inside `y_boat_sim`.
   - `boat_dev` runs headless. Because both containers share `ROS_DOMAIN_ID=10`, `--network host`, and `--ipc host`, they share a single DDS graph. Run production nodes in `boat_dev`, and launch interactive/GUI tools in `y_boat_sim`.
2. **Mandatory Simulation Time (`use_sim_time:=true`)**:
   - Gazebo runs at sim time (~800s to a few thousand seconds), while the host clock is at ~1.79 billion seconds. All nodes and CLI tools (`tf2_echo`, `view_frames`) must run with `-p use_sim_time:=true` to avoid immediate extrapolation failures.
3. **Clean Colcon Workspace**:
   - All builds must occur from `/workspace`, not `/workspace/src`. Stale overlays in `src/` (`src/build`, `src/install`, `src/log`) must remain deleted to avoid overlay conflicts.

---

## 3. Key Concepts & Traps to Understand

### Trap 1: Why `msg.header.frame_id` is `map` (and why that's not a bug)
On a ground robot with wheel encoders, `odom -> base_link` is smooth but drifts, while `map -> odom` is the jumpy correction from a localization system (like AMCL).
The BlueBoat has no wheel encoders and no prior obstacle map. ArduPilot's internal EKF fuses GPS + IMU into a single globally-referenced estimate. MAVROS honestly labels `/mavros/local_position/odom` with `frame_id: 'map'`.
- **The Trap**: If your node blindly copies `msg.header.frame_id` as the transform's parent frame, it will broadcast `map -> base_link`, breaking Nav2's required `map -> odom -> base_link` contract.
- **The Fix**: Hardcode the parent as `odom` and child as `base_link`. Broadcast `map -> odom` once as an identity transform using `StaticTransformBroadcaster`.

### Trap 2: Broadcaster Lifecycle & Garbage Collection
`TransformBroadcaster` and `StaticTransformBroadcaster` wrap ROS 2 publishers.
- **The Trap**: If created as local variables in `__init__`, Python's garbage collector destroys them when `__init__` returns. The node will spin silently without publishing any TF.
- **The Fix**: Always store them as instance attributes (`self.tf_broadcaster = ...`).

### Trap 3: ArduPilot's 3-Second Guided Timeout
In ArduPilot (`Rover/mode_guided.cpp`), if a new guided setpoint is not received within 3.0 seconds (`millis() - _des_att_time_ms > 3000`), the vehicle enters a failsafe/loiter state.
- **The Fix**: The `cmd_vel_bridge` must run a 10 Hz timer (`create_timer(0.1, ...)`) that continually publishes the latest command, defaulting to $0.0\text{ m/s}$ keepalives when no `/cmd_vel` is incoming.

---

## 4. Step-by-Step Learning Execution Path

### Step 0: Package Setup (Completed)
- Package created at `src/nodes/boat_nav`.
- Verified `ros2 pkg prefix boat_nav` points to `/workspace/install/boat_nav`.
- Declared dependencies: `rclpy`, `geometry_msgs`, `nav_msgs`, `tf2_ros`, `tf2_ros_py`, `mavros_msgs`.

---

### Step 1: Write `tf_publisher.py`

#### Concept Check
- Dynamic `TransformBroadcaster` (`/tf`, volatile QoS, interpolated timestamps) vs `StaticTransformBroadcaster` (`/tf_static`, transient-local latched, published once).
- Type conversion: `Odometry` carries `Point` + `Quaternion`; `TransformStamped` carries `Vector3` + `Quaternion`. Field-by-field copy is required.
- Stamping: Must copy `msg.header.stamp`, not `now()`, to prevent downstream jitter and future-extrapolation errors.

#### Skeleton to Implement
Create `src/nodes/boat_nav/boat_nav/tf_publisher.py`:

```python
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy, DurabilityPolicy

from nav_msgs.msg import Odometry
from geometry_msgs.msg import TransformStamped
from tf2_ros import TransformBroadcaster, StaticTransformBroadcaster

SENSOR_QOS = QoSProfile(
    reliability=ReliabilityPolicy.BEST_EFFORT,
    history=HistoryPolicy.KEEP_LAST,
    depth=10,
    durability=DurabilityPolicy.VOLATILE,
)

MAP_FRAME = 'map'
ODOM_FRAME = 'odom'
BASE_FRAME = 'base_link'


class BoatTfPublisher(Node):
    def __init__(self):
        super().__init__('boat_tf_publisher')

        # TODO 1: Create and STORE the dynamic broadcaster on self
        # TODO 2: Create and STORE the static broadcaster on self

        # TODO 3: Build the identity map -> odom TransformStamped and send it ONCE here.
        #         Identity rotation is w=1.0 (all zeros is invalid).

        self.create_subscription(
            Odometry,
            '/mavros/local_position/odom',
            self._odom_cb,
            SENSOR_QOS
        )

    def _odom_cb(self, msg: Odometry):
        # TODO 4: Build a TransformStamped for odom -> base_link
        #   header.stamp    <- copy from msg.header.stamp
        #   header.frame_id <- ODOM_FRAME (do not use msg.header.frame_id)
        #   child_frame_id  <- BASE_FRAME
        #   translation.x/y/z <- msg.pose.pose.position.x/y/z
        #   rotation.x/y/z/w  <- msg.pose.pose.orientation.x/y/z/w
        #
        # TODO 5: Broadcast it using the dynamic broadcaster
        pass


def main(args=None):
    rclpy.init(args=args)
    node = BoatTfPublisher()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
```

#### Verification Commands
```bash
# Add entry point to setup.py: 'boat_tf_publisher = boat_nav.tf_publisher:main'
cd /workspace
colcon build --symlink-install --packages-select boat_nav
source install/setup.bash

# Run in boat_dev:
ros2 run boat_nav boat_tf_publisher --ros-args -p use_sim_time:=true

# Verify in a second shell:
ros2 run tf2_ros tf2_echo odom base_link --ros-args -p use_sim_time:=true
ros2 run tf2_tools view_frames --ros-args -p use_sim_time:=true
```

---

### Step 2: Write `cmd_vel_bridge.py`

#### Concept Check
- Nav2 publishes `geometry_msgs/Twist` on `/cmd_vel` representing body-frame velocities.
- MAVROS `setpoint_velocity/cmd_vel_unstamped` treats velocity in world ENU (fixed compass direction).
- The bridge must convert `Twist` to `mavros_msgs/PositionTarget` on `/mavros/setpoint_raw/local` using `FRAME_BODY_NED`.
- Timer pattern: Callbacks only cache incoming messages; a 10 Hz periodic timer executes publication to maintain ArduPilot's watchdog keepalive.

#### Skeleton to Implement
Create `src/nodes/boat_nav/boat_nav/cmd_vel_bridge.py`:

```python
import rclpy
from rclpy.node import Node
from geometry_msgs.msg import Twist
from mavros_msgs.msg import PositionTarget

# Mask flags to ignore everything except forward/lateral velocity and yaw rate:
VELOCITY_YAW_RATE_MASK = (
    PositionTarget.IGNORE_PX | PositionTarget.IGNORE_PY | PositionTarget.IGNORE_PZ |
    PositionTarget.IGNORE_AFX | PositionTarget.IGNORE_AFY | PositionTarget.IGNORE_AFZ |
    PositionTarget.IGNORE_YAW
)


class CmdVelBridge(Node):
    def __init__(self):
        super().__init__('cmd_vel_bridge')

        self.last_twist = Twist()

        self.sub_cmd_vel = self.create_subscription(
            Twist,
            '/cmd_vel',
            self._cmd_vel_cb,
            10
        )
        self.pub_setpoint = self.create_publisher(
            PositionTarget,
            '/mavros/setpoint_raw/local',
            10
        )

        # 10 Hz timer loop
        self.timer = self.create_timer(0.1, self._timer_cb)

    def _cmd_vel_cb(self, msg: Twist):
        # TODO 1: Cache the incoming twist message
        pass

    def _timer_cb(self):
        # TODO 2: Build PositionTarget message
        #   header.stamp = self.get_clock().now().to_msg()
        #   header.frame_id = 'base_link'
        #   coordinate_frame = PositionTarget.FRAME_BODY_NED (8)
        #   type_mask = VELOCITY_YAW_RATE_MASK
        #   velocity.x = self.last_twist.linear.x
        #   velocity.y = 0.0  (skid-steer boat cannot strafe)
        #   velocity.z = 0.0
        #   yaw_rate = self.last_twist.angular.z
        #
        # TODO 3: Publish to self.pub_setpoint
        pass


def main(args=None):
    rclpy.init(args=args)
    node = CmdVelBridge()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
```

#### Verification Commands
```bash
# Add entry point to setup.py: 'cmd_vel_bridge = boat_nav.cmd_vel_bridge:main'
cd /workspace && colcon build --symlink-install --packages-select boat_nav && source install/setup.bash

# Ensure boat is armed and in GUIDED mode (via MAVROS service calls or QGC)
# Run node:
ros2 run boat_nav cmd_vel_bridge --ros-args -p use_sim_time:=true

# Publish forward velocity:
ros2 topic pub -r 10 /cmd_vel geometry_msgs/msg/Twist "{linear: {x: 1.0}}"
# Confirm forward motion; stop publishing and verify clean deceleration with zero-stutter.
```

---

### Step 3: Conclusive Body-Frame Heading Verification
1. Command a yaw rate on `/cmd_vel` to rotate the boat ~90°.
2. Command forward velocity $+X$.
3. Verify that the vessel travels in the direction it is pointing (not fixed North).

---

### Step 4: Stream Rate Boost & Launch File

#### Telemetry Rate Bump
```bash
# Call MAVROS service to set LOCAL_POSITION_NED (ID 32) stream to 20 Hz:
ros2 service call /mavros/set_message_interval mavros_msgs/srv/MessageInterval "{message_id: 32, message_rate: 20.0}"
# Verify:
ros2 topic hz /mavros/local_position/odom
```

#### Launch File (`src/nodes/boat_nav/launch/nav_bringup.launch.py`)
```python
from launch import LaunchDescription
from launch_ros.actions import Node

def generate_launch_description():
    return LaunchDescription([
        Node(
            package='boat_nav',
            executable='boat_tf_publisher',
            name='boat_tf_publisher',
            parameters=[{'use_sim_time': True}],
            output='screen',
        ),
        Node(
            package='boat_nav',
            executable='cmd_vel_bridge',
            name='cmd_vel_bridge',
            parameters=[{'use_sim_time': True}],
            output='screen',
        ),
    ])
```

---

### Step 5: Full Milestone Proof

1. **Terminal 1 (`boat_dev`)**:
   ```bash
   ros2 launch boat_nav nav_bringup.launch.py
   ```
2. **Terminal 2 (`y_boat_sim`)**:
   ```bash
   source /opt/ros/jazzy/setup.bash
   ros2 run teleop_twist_keyboard teleop_twist_keyboard
   ```
3. **Terminal 3 (`y_boat_sim`)**:
   ```bash
   source /opt/ros/jazzy/setup.bash
   rviz2 -d /home/simuser/sim_scratch/rviz/nav_debug.rviz  # (or default config)
   ```
4. **Milestone Met**: Driving via keyboard teleop updates vehicle position and heading live across RViz, Gazebo, and the connected TF tree.
