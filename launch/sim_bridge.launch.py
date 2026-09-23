"""Bridge Gazebo -> ROS 2 for the BlueBoat scratch sim.

Brings up /clock (sim time) and ground-truth odometry on /sim/ground_truth/odom.
No sensor bridges in this step.

    ros2 launch ~/sim_scratch/launch/sim_bridge.launch.py
"""
import os

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node

SCRATCH_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def generate_launch_description():
    config_file = LaunchConfiguration("config_file")

    return LaunchDescription([
        DeclareLaunchArgument(
            "config_file",
            default_value=os.path.join(SCRATCH_DIR, "bridge.yaml"),
            description="ros_gz_bridge YAML config.",
        ),
        Node(
            package="ros_gz_bridge",
            executable="parameter_bridge",
            name="sim_bridge",
            output="screen",
            # NOTE: use_sim_time is deliberately NOT set on this node. It is the process
            # that publishes /clock, so making it wait on /clock would be circular.
            # Every *other* node in the graph should be launched with use_sim_time:=true.
            parameters=[{"config_file": config_file}],
        ),
    ])
