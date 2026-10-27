"""Start the RoboBoat course with the BlueBoat and ArduPilot SITL.

The world runs headless (no Gazebo window). Its scene broadcaster stays on so a
Gazebo window or the web viewer can connect later.

Two viewers start with it (turn either off with foxglove:=false or web:=false):
  - Foxglove bridge on port 18765, for ROS topics in Foxglove
  - The browser viewer: its page on port 18080, and the Gazebo websocket it
    streams the world from on port 19090
The compose ports service publishes them as 8765, 8080 and 9090. Docker Desktop
does not expose host-network ports to your computer, so they can't be used directly.

sensors:=false (the default) leaves out the camera and LiDAR. They render on the
CPU without a GPU, and because Gazebo and ArduPilot run in lockstep, that slows
the whole sim to a crawl. GPS and IMU still work. Use sensors:=true on a machine
with a GPU.

Gazebo starts first. The boat is spawned once the world is up.
"""
import os
import re
import subprocess

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import (
    DeclareLaunchArgument,
    ExecuteProcess,
    OpaqueFunction,
    IncludeLaunchDescription,
    TimerAction,
)
from launch.conditions import IfCondition
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import ComposableNodeContainer, Node
from ros_gz_bridge.actions import RosGzBridge
from ros_gz_sim.actions import GzServer

WORLD_SDF = '/tmp/roboboat.sdf'

# Start pose on the RoboBoat course, from cougars-dev's blueboat_roboboat_params.yaml
START_POSITION = '[-226.3, 1060.4, 0.0]'
START_ORIENTATION = '[0.0, 0.0, 3.14159]'  # yaw 180 deg


def write_world(context, coug_gazebo):
    """Turn coug_gazebo's world template into a plain SDF file."""
    # headless:=false keeps the scene broadcaster; we just never open a window
    sdf = subprocess.check_output([
        'xacro', 'headless:=false',
        os.path.join(coug_gazebo, 'worlds', 'roboboat.sdf.xacro'),
    ]).decode()
    if LaunchConfiguration('sensors').perform(context) != 'true':
        # Without this system, cameras and LiDAR are never rendered
        sdf = re.sub(r'<plugin\s+filename="gz-sim-sensors-system".*?</plugin>',
                     '', sdf, flags=re.S)
    with open(WORLD_SDF, 'w') as f:
        f.write(sdf)
    return []


def generate_launch_description():
    coug_gazebo = get_package_share_directory('coug_gazebo')
    config_dir = os.environ['CONFIG_DIR']
    scenario = os.path.join(config_dir, 'gazebo', 'roboboat_params.yaml')

    # coug_gazebo's bridges load into this container, so its name must match
    container = ComposableNodeContainer(
        package='rclcpp_components',
        executable='component_container_isolated',
        name='gazebo_container',
        namespace='',
    )
    server = GzServer(
        world_sdf_file=WORLD_SDF,
        container_name='/gazebo_container',
        use_composition=True,
        verbosity_level=LaunchConfiguration('gz_verbosity'),
    )
    clock_bridge = RosGzBridge(
        bridge_name='clock_bridge_node',
        config_file=os.path.join(coug_gazebo, 'config', 'clock_bridge.yaml'),
        container_name='/gazebo_container',
        use_composition=True,
    )

    boat = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(
            os.path.join(coug_gazebo, 'launch', 'coug_gazebo_agent.launch.py')),
        launch_arguments={
            'agent_ns': 'yboat1gz',
            'use_sim_time': 'true',
            'scenario_param_file': scenario,
            'initial_position': START_POSITION,
            'initial_orientation': START_ORIENTATION,
        }.items(),
    )

    # Forward ArduPilot's first MAVLink port (TCP 5760) to QGroundControl on your
    # computer (UDP 14550, QGC's default, so it connects by itself). ArduPilot's
    # other ports stay free: 5762 for the ArduPilot terminal, 5763 for MAVROS.
    qgc_forwarder = ExecuteProcess(
        cmd=['mavproxy.py', '--master', 'tcp:127.0.0.1:5760',
             '--out', ['udp:', LaunchConfiguration('qgc_host'), ':14550'],
             '--daemon', '--non-interactive', '--state-basedir', '/tmp/mavproxy'],
        output='log',
        respawn=True,
        respawn_delay=3.0,
    )

    # MAVROS on ArduPilot's third port (TCP 5763). Our cmd_vel_bridge talks to it.
    mavros = Node(
        package='mavros',
        executable='mavros_node',
        output='log',
        parameters=[{
            'fcu_url': 'tcp://127.0.0.1:5763',
            'tgt_system': 1,
            'use_sim_time': True,
        }],
    )

    # Viewers. Neither touches the sim's timing, so they're on by default.
    # The bridge relays messages with their own timestamps, so it doesn't need
    # sim time; following /clock at 250 Hz would cost it a third of a core.
    foxglove = Node(
        package='foxglove_bridge',
        executable='foxglove_bridge',
        output='log',
        parameters=[{'port': 18765}],
        condition=IfCondition(LaunchConfiguration('foxglove')),
    )
    web_stream = ExecuteProcess(
        cmd=['gz', 'launch', os.path.join(config_dir, 'web', 'websocket.gzlaunch')],
        output='log',
        condition=IfCondition(LaunchConfiguration('web')),
    )
    web_page = ExecuteProcess(
        cmd=['python3', '-m', 'http.server', '18080', '--directory', '/sim/web'],
        output='log',
        condition=IfCondition(LaunchConfiguration('web')),
    )

    return LaunchDescription([
        DeclareLaunchArgument('gz_verbosity', default_value='1'),
        DeclareLaunchArgument('sensors', default_value='false',
                              description='Render camera and LiDAR (needs a GPU)'),
        DeclareLaunchArgument('qgc_host', default_value='host.docker.internal',
                              description='Computer running QGroundControl'),
        DeclareLaunchArgument('foxglove', default_value='true',
                              description='Foxglove bridge on port 18765'),
        DeclareLaunchArgument('web', default_value='true',
                              description='Browser viewer on ports 18080 and 19090'),
        OpaqueFunction(function=write_world, args=[coug_gazebo]),
        container, server, clock_bridge,
        # Give the world a few seconds to load before spawning the boat
        TimerAction(period=5.0, actions=[boat]),
        # ArduPilot opens its ports a few seconds after the boat spawns
        TimerAction(period=10.0, actions=[qgc_forwarder, mavros, foxglove, web_stream, web_page]),
    ])
