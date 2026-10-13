#!/usr/bin/env python3
"""Republish Gazebo's clock at a lower rate.

Gazebo publishes the clock once per physics step (250 Hz). Every node running with
use_sim_time subscribes to /clock, and MAVROS alone is ~59 nodes, so at the full rate
it spent ~1.8 cores just tracking time and stole CPU from the lockstep physics. 50 Hz
(20 ms resolution) is plenty for everything in the ROS graph.

  /sim/clock_raw (every step, from ros_gz_bridge)  ->  /clock (CLOCK_RATE_HZ, default 50)
"""
import os

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, DurabilityPolicy
from rosgraph_msgs.msg import Clock


class ClockThrottle(Node):
    def __init__(self):
        super().__init__("clock_throttle")
        self.period_ns = int(1e9 / float(os.environ.get("CLOCK_RATE_HZ", "50")))
        self.last_ns = None
        # /clock uses best-effort, keep-last-1 in ROS 2 (rclcpp's TimeSource default).
        qos = QoSProfile(depth=1, reliability=ReliabilityPolicy.BEST_EFFORT,
                         durability=DurabilityPolicy.VOLATILE)
        self.pub = self.create_publisher(Clock, "/clock", qos)
        self.create_subscription(Clock, "/sim/clock_raw", self.on_clock, qos)

    def on_clock(self, msg):
        now_ns = msg.clock.sec * 1_000_000_000 + msg.clock.nanosec
        # Always forward a backwards jump (world reset) so nodes see it immediately.
        if self.last_ns is None or now_ns < self.last_ns or now_ns - self.last_ns >= self.period_ns:
            self.last_ns = now_ns
            self.pub.publish(msg)


def main():
    rclpy.init()
    rclpy.spin(ClockThrottle())


if __name__ == "__main__":
    main()
