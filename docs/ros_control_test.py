#!/usr/bin/env python3
"""Control the BlueBoat from ROS 2 only (no MAVProxy commands).

Covers:
  1. GUIDED via /mavros/set_mode, arm via /mavros/cmd/arming
  2. a position setpoint, confirming arrival
  3. a BODY-FRAME velocity setpoint (forward + yaw rate), tested at two headings,
     confirming the boat moves forward relative to its own heading rather than in a
     fixed world direction
  4. how long ArduPilot keeps moving after setpoints stop (GUIDED timeout)

Body-frame velocity is the interesting one. /mavros/setpoint_velocity/cmd_vel_unstamped
is interpreted in the LOCAL ENU frame, so it will not do what a Nav2 cmd_vel needs.
Body frame requires /mavros/setpoint_raw/local (mavros_msgs/PositionTarget) with
coordinate_frame = FRAME_BODY_NED (8) and a type_mask that ignores position/accel/yaw
and keeps velocity + yaw_rate.

    ros2 run ... no; just: python3 ros_control_test.py
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

# PositionTarget.type_mask: ignore position (1|2|4), ignore accel (64|128|256),
# ignore yaw (1024); keep velocity + yaw_rate.
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


def ang_diff(a, b):
    """Smallest signed difference a-b, wrapped to [-pi, pi]."""
    return (a - b + math.pi) % (2 * math.pi) - math.pi


class Ctl(Node):
    def __init__(self):
        super().__init__("blueboat_ros_control_test")
        self.state = None
        self.odom = None
        self.create_subscription(State, "/mavros/state", self._state_cb, 10)
        self.create_subscription(Odometry, "/mavros/local_position/odom",
                                 self._odom_cb, SENSOR_QOS)
        self.sp_raw = self.create_publisher(PositionTarget, "/mavros/setpoint_raw/local", 10)
        self.sp_pos = self.create_publisher(PoseStamped, "/mavros/setpoint_position/local", 10)
        self.cli_mode = self.create_client(SetMode, "/mavros/set_mode")
        self.cli_arm = self.create_client(CommandBool, "/mavros/cmd/arming")

    def _state_cb(self, msg):
        self.state = msg

    def _odom_cb(self, msg):
        self.odom = msg

    def spin(self, seconds):
        t0 = time.time()
        while time.time() - t0 < seconds:
            rclpy.spin_once(self, timeout_sec=0.05)

    def wait_state(self, timeout=60):
        t0 = time.time()
        while time.time() - t0 < timeout:
            rclpy.spin_once(self, timeout_sec=0.2)
            if self.state is not None and self.odom is not None:
                return True
        return False

    def xy(self):
        p = self.odom.pose.pose.position
        return p.x, p.y

    def yaw(self):
        return yaw_from_quat(self.odom.pose.pose.orientation)

    def set_mode(self, mode):
        self.cli_mode.wait_for_service(timeout_sec=10)
        req = SetMode.Request()
        req.custom_mode = mode
        fut = self.cli_mode.call_async(req)
        rclpy.spin_until_future_complete(self, fut, timeout_sec=10)
        ok = fut.result() is not None and fut.result().mode_sent
        print(f"[mode] set_mode({mode}) mode_sent={ok}")
        self.spin(3)
        print(f"[mode] state.mode={self.state.mode}")
        return ok

    def arm(self, value=True):
        self.cli_arm.wait_for_service(timeout_sec=10)
        req = CommandBool.Request()
        req.value = value
        fut = self.cli_arm.call_async(req)
        rclpy.spin_until_future_complete(self, fut, timeout_sec=10)
        res = fut.result()
        print(f"[arm] arming({value}) success={getattr(res,'success',None)} "
              f"result={getattr(res,'result',None)}")
        self.spin(2)
        print(f"[arm] state.armed={self.state.armed}")
        return getattr(res, "success", False)

    def body_velocity(self, vx, yaw_rate, duration, rate_hz=10.0):
        """Stream a body-frame velocity setpoint."""
        msg = PositionTarget()
        msg.coordinate_frame = PositionTarget.FRAME_BODY_NED
        msg.type_mask = VEL_YAWRATE_MASK
        msg.velocity.x = float(vx)      # forward, in body frame
        msg.velocity.y = 0.0
        msg.velocity.z = 0.0
        msg.yaw_rate = float(yaw_rate)
        period = 1.0 / rate_hz
        t0 = time.time()
        while time.time() - t0 < duration:
            msg.header.stamp = self.get_clock().now().to_msg()
            self.sp_raw.publish(msg)
            rclpy.spin_once(self, timeout_sec=period)

    def position_setpoint(self, x, y, duration=120, tol=5.0, rate_hz=10.0):
        msg = PoseStamped()
        msg.header.frame_id = "map"
        msg.pose.position.x = float(x)
        msg.pose.position.y = float(y)
        msg.pose.orientation.w = 1.0
        period = 1.0 / rate_hz
        t0 = time.time()
        best = None
        while time.time() - t0 < duration:
            msg.header.stamp = self.get_clock().now().to_msg()
            self.sp_pos.publish(msg)
            rclpy.spin_once(self, timeout_sec=period)
            cx, cy = self.xy()
            d = math.hypot(x - cx, y - cy)
            best = d if best is None else min(best, d)
            if d < tol:
                print(f"[pos] ARRIVED within {d:.1f} m after {time.time()-t0:.0f}s")
                return True
        print(f"[pos] closest approach {best:.1f} m in {duration}s")
        return False


def heading_test(c, label):
    """Command forward body velocity and compare travel direction to heading."""
    c.spin(1)
    yaw0 = c.yaw()
    x0, y0 = c.xy()
    print(f"\n[{label}] heading before = {math.degrees(yaw0):6.1f} deg, "
          f"pos = ({x0:.1f}, {y0:.1f})")
    c.body_velocity(vx=1.5, yaw_rate=0.0, duration=12)
    c.spin(1)
    x1, y1 = c.xy()
    dx, dy = x1 - x0, y1 - y0
    dist = math.hypot(dx, dy)
    travel_dir = math.atan2(dy, dx)
    err = math.degrees(abs(ang_diff(travel_dir, yaw0)))
    print(f"[{label}] moved {dist:5.1f} m, travel dir = {math.degrees(travel_dir):6.1f} deg, "
          f"|travel - heading| = {err:5.1f} deg")
    return yaw0, travel_dir, dist, err


def main():
    rclpy.init()
    c = Ctl()
    if not c.wait_state():
        print("no /mavros/state or /mavros/local_position/odom - is MAVROS up?")
        return 1
    print(f"[conn] connected={c.state.connected} mode={c.state.mode} armed={c.state.armed}")

    c.set_mode("GUIDED")
    c.arm(True)

    # --- position setpoint ---
    print("\n=== position setpoint ===")
    x0, y0 = c.xy()
    c.position_setpoint(x0 + 30.0, y0 + 0.0)

    # --- body-frame velocity, heading A ---
    print("\n=== body-frame velocity: heading A ===")
    a = heading_test(c, "headingA")

    # --- rotate ~90 deg, then repeat ---
    print("\n=== rotating ~90 deg ===")
    c.body_velocity(vx=0.0, yaw_rate=0.4, duration=8)
    c.spin(2)

    print("\n=== body-frame velocity: heading B ===")
    b = heading_test(c, "headingB")

    print(f"\n[body-frame] heading A {math.degrees(a[0]):.1f} deg -> travel {math.degrees(a[1]):.1f} deg (err {a[3]:.1f})")
    print(f"[body-frame] heading B {math.degrees(b[0]):.1f} deg -> travel {math.degrees(b[1]):.1f} deg (err {b[3]:.1f})")
    hdg_change = abs(math.degrees(ang_diff(b[0], a[0])))
    print(f"[body-frame] heading changed by {hdg_change:.1f} deg between tests")
    if a[3] < 30 and b[3] < 30 and hdg_change > 20:
        print("[body-frame] PASS: travel follows heading at two different headings")
    else:
        print("[body-frame] INCONCLUSIVE - see numbers above")

    # --- GUIDED timeout ---
    print("\n=== GUIDED timeout (stop sending setpoints, watch it coast) ===")
    c.body_velocity(vx=1.5, yaw_rate=0.0, duration=8)
    t_stop = time.time()
    last = c.xy()
    stopped_at = None
    while time.time() - t_stop < 20:
        c.spin(0.5)
        cur = c.xy()
        step = math.hypot(cur[0] - last[0], cur[1] - last[1])
        speed = step / 0.5
        el = time.time() - t_stop
        print(f"[timeout] t+{el:4.1f}s  speed ~{speed:4.2f} m/s")
        if speed < 0.05 and stopped_at is None:
            stopped_at = el
            print(f"[timeout] effectively stopped {el:.1f}s after last setpoint")
            break
        last = cur

    c.arm(False)
    rclpy.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
