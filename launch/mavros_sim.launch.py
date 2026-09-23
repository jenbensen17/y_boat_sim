"""MAVROS (ArduPilot flavour) for the BlueBoat scratch sim.

Wraps MAVROS's own apm launch so we keep its plugin lists and config, while forcing
use_sim_time:=true for every node in scope (SetParameter applies to the whole
LaunchDescription, which is why the include is nested under it).

    ros2 launch ~/sim_scratch/launch/mavros_sim.launch.py

fcu_url defaults to the UDP output that launch_blueboat.sh reserves for MAVROS (14551);
MAVProxy keeps 14550 for a GCS.
"""
import os

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription
from launch.launch_description_sources import AnyLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import SetParameter
from ament_index_python.packages import get_package_share_directory


def _apm_launch_path():
    share = get_package_share_directory("mavros")
    for candidate in ("apm.launch", "apm.launch.py", "apm.launch.xml"):
        path = os.path.join(share, "launch", candidate)
        if os.path.exists(path):
            return path
    raise FileNotFoundError(
        f"No apm launch file found under {os.path.join(share, 'launch')}")


def generate_launch_description():
    fcu_url = LaunchConfiguration("fcu_url")
    tgt_system = LaunchConfiguration("tgt_system")

    return LaunchDescription([
        DeclareLaunchArgument(
            "fcu_url",
            default_value="udp://127.0.0.1:14551@",
            description="MAVLink endpoint. 14551 is the output reserved for MAVROS.",
        ),
        DeclareLaunchArgument("tgt_system", default_value="1"),

        # Applies to everything below, including the included MAVROS nodes.
        SetParameter(name="use_sim_time", value=True),

        IncludeLaunchDescription(
            AnyLaunchDescriptionSource(_apm_launch_path()),
            launch_arguments={
                "fcu_url": fcu_url,
                "tgt_system": tgt_system,
            }.items(),
        ),
    ])
