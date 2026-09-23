#!/usr/bin/env python3
"""RoboBoat Verification Test Script.

Validates that:
1. MAVROS is connected and publishing state & odometry.
2. The boat can switch to GUIDED mode and arm via ROS 2 services.
3. Forward velocity setpoints on /mavros/setpoint_raw/local move the boat forward.
4. Odometry updates in real-time, allowing teammates to watch the boat move in
   both Gazebo and QGroundControl.
5. The boat halts and disarms cleanly.

Usage:
    python3 test_boat_drive.py
"""
import math
import sys
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy, DurabilityPolicy

from geometry_msgs.msg import PoseStamped
from nav_msgs.msg import Odometry
from mavros_msgs.msg import PositionTarget, State
from mavros_msgs.srv import CommandBool, SetMode

# Mask to ignore position and acceleration, keeping velocity and yaw_rate
IGNORE_POS = PositionTarget.IGNORE_PX | PositionTarget.IGNORE_PY | PositionTarget.IGNORE_PZ
IGNORE_ACC = PositionTarget.IGNORE_AFX | PositionTarget.IGNORE_AFY | PositionTarget.IGNORE_AFZ
VEL_YAWRATE_MASK = IGNORE_POS | IGNORE_ACC | PositionTarget.IGNORE_YAW

SENSOR_QOS = QoSProfile(
    reliability=ReliabilityPolicy.BEST_EFFORT,
    history=HistoryPolicy.KEEP_LAST,
    depth=10,
    durability=DurabilityPolicy.VOLATILE,
)


def yaw_from_quat(q):
    siny = 2.0 * (q.w * q.z + q.x * q.y)
    cosy = 1.0 - 2.0 * (q.y * q.y + q.z * q.z)
    return math.atan2(siny, cosy)


class BoatTestNode(Node):
    def __init__(self):
        super().__init__("blueboat_drive_test")
        self.state = None
        self.odom = None

        self.create_subscription(State, "/mavros/state", self._state_cb, 10)
        self.create_subscription(
            Odometry, "/mavros/local_position/odom", self._odom_cb, SENSOR_QOS
        )

        self.sp_raw = self.create_publisher(
            PositionTarget, "/mavros/setpoint_raw/local", 10
        )
        self.cli_mode = self.create_client(SetMode, "/mavros/set_mode")
        self.cli_arm = self.create_client(CommandBool, "/mavros/cmd/arming")

    def _state_cb(self, msg):
        self.state = msg

    def _odom_cb(self, msg):
        self.odom = msg

    def spin_duration(self, seconds):
        t0 = time.time()
        while time.time() - t0 < seconds:
            rclpy.spin_once(self, timeout_sec=0.05)

    def wait_for_connection(self, timeout=30.0):
        self.get_logger().info("Connecting to MAVROS...")
        t0 = time.time()
        while time.time() - t0 < timeout:
            rclpy.spin_once(self, timeout_sec=0.2)
            if self.state is not None and self.state.connected and self.odom is not None:
                return True
        return False

    def get_xy(self):
        p = self.odom.pose.pose.position
        return p.x, p.y

    def get_yaw_deg(self):
        return math.degrees(yaw_from_quat(self.odom.pose.pose.orientation))

    def set_mode(self, mode_name):
        self.get_logger().info(f"Setting mode to {mode_name}...")
        if not self.cli_mode.wait_for_service(timeout_sec=5.0):
            self.get_logger().error("Service /mavros/set_mode unavailable!")
            return False

        req = SetMode.Request()
        req.custom_mode = mode_name
        fut = self.cli_mode.call_async(req)
        rclpy.spin_until_future_complete(self, fut, timeout_sec=5.0)

        res = fut.result()
        if res and res.mode_sent:
            self.spin_duration(2.0)
            self.get_logger().info(f"Mode is now: {self.state.mode}")
            return True
        self.get_logger().error("Failed to set mode!")
        return False

    def set_armed(self, arm=True, max_retries=10):
        action = "Arming" if arm else "Disarming"
        self.get_logger().info(f"{action} throttle...")
        if not self.cli_arm.wait_for_service(timeout_sec=5.0):
            self.get_logger().error("Service /mavros/cmd/arming unavailable!")
            return False

        for attempt in range(1, max_retries + 1):
            req = CommandBool.Request()
            req.value = arm
            fut = self.cli_arm.call_async(req)
            rclpy.spin_until_future_complete(self, fut, timeout_sec=5.0)

            res = fut.result()
            if res and res.success:
                self.spin_duration(2.0)
                self.get_logger().info(f"Armed status: {self.state.armed}")
                return True

            if not arm:
                break

            self.get_logger().info(
                f"Waiting for pre-arm checks to settle (attempt {attempt}/{max_retries})..."
            )
            self.spin_duration(2.0)

        self.get_logger().error(f"Failed to {action.lower()} vehicle!")
        return False

    def send_body_velocity(self, vx=1.5, yaw_rate=0.0, duration=8.0, rate_hz=10.0):
        self.get_logger().info(
            f"Streaming forward velocity {vx:.1f} m/s in body frame for {duration:.1f}s..."
        )
        msg = PositionTarget()
        msg.coordinate_frame = PositionTarget.FRAME_BODY_NED
        msg.type_mask = VEL_YAWRATE_MASK
        msg.velocity.x = float(vx)
        msg.velocity.y = 0.0
        msg.velocity.z = 0.0
        msg.yaw_rate = float(yaw_rate)

        period = 1.0 / rate_hz
        t0 = time.time()
        last_print = 0.0
        x_start, y_start = self.get_xy()

        while time.time() - t0 < duration:
            msg.header.stamp = self.get_clock().now().to_msg()
            self.sp_raw.publish(msg)
            rclpy.spin_once(self, timeout_sec=period)

            elapsed = time.time() - t0
            if elapsed - last_print >= 2.0:
                cx, cy = self.get_xy()
                dist = math.hypot(cx - x_start, cy - y_start)
                self.get_logger().info(
                    f"  t={elapsed:4.1f}s | Current pos: ({cx:5.1f}, {cy:5.1f}) | Distance: {dist:4.1f} m"
                )
                last_print = elapsed

        # Send zero-velocity stop command
        msg.velocity.x = 0.0
        msg.yaw_rate = 0.0
        msg.header.stamp = self.get_clock().now().to_msg()
        self.sp_raw.publish(msg)
        self.spin_duration(1.0)


def main():
    rclpy.init()
    node = BoatTestNode()

    print("=" * 65)
    print("      RoboBoat BlueBoat ROS 2 Simulation Verification Test")
    print("=" * 65)

    if not node.wait_for_connection(timeout=30.0):
        print("\n[ERROR] Could not connect to /mavros/state or /mavros/local_position/odom!")
        print("Please ensure the simulator is running with: ./sim_scratch/run_sim_scratch.sh")
        rclpy.shutdown()
        return 1

    x0, y0 = node.get_xy()
    yaw0 = node.get_yaw_deg()
    print(f"\n[INFO] Connected to vehicle!")
    print(f"  Initial Mode:     {node.state.mode}")
    print(f"  Initial Armed:    {node.state.armed}")
    print(f"  Initial Position: ({x0:.2f}, {y0:.2f})")
    print(f"  Initial Heading:  {yaw0:.1f}°\n")

    # 1. Switch to GUIDED mode
    if not node.set_mode("GUIDED"):
        rclpy.shutdown()
        return 1

    # 2. Arm vehicle
    if not node.set_armed(True):
        rclpy.shutdown()
        return 1

    # 3. Drive boat forward for 8 seconds
    node.send_body_velocity(vx=1.5, yaw_rate=0.0, duration=8.0)

    # 4. Disarm vehicle
    node.set_armed(False)

    x1, y1 = node.get_xy()
    yaw1 = node.get_yaw_deg()
    distance_traveled = math.hypot(x1 - x0, y1 - y0)

    print("\n" + "=" * 65)
    print("                   TEST SUMMARY & RESULTS")
    print("=" * 65)
    print(f"  Starting Position: ({x0:6.2f}, {y0:6.2f})")
    print(f"  Ending Position:   ({x1:6.2f}, {y1:6.2f})")
    print(f"  Total Distance:    {distance_traveled:6.2f} meters")
    print(f"  Final Heading:     {yaw1:6.1f}°")

    if distance_traveled >= 3.0:
        print("\n[SUCCESS] The boat successfully armed, drove forward, and updated odometry!")
        print("          You should have seen the boat move in Gazebo and QGroundControl.")
        print("=" * 65 + "\n")
        exit_code = 0
    else:
        print(f"\n[FAILURE] Boat moved only {distance_traveled:.2f} m (expected >= 3.0 m).")
        print("=" * 65 + "\n")
        exit_code = 1

    rclpy.shutdown()
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
