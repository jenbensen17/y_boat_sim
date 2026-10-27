# The sim's environment. entrypoint.sh sources it for every command, and
# .bashrc sources it for interactive shells.
source /opt/ros/jazzy/setup.bash
source /ws/install/setup.bash

# Where Gazebo finds models: the course objects and the BlueBoat meshes. The
# server, the Gazebo window and the web viewer all need the same paths.
export GZ_SIM_RESOURCE_PATH="/ws/install/coug_gazebo/share/coug_gazebo/models/roboboat:/ws/install/coug_gazebo/share:/ws/install/coug_description/share:${GZ_SIM_RESOURCE_PATH}"

# Gazebo only talks to processes in the same partition. Fixing the name lets the
# Gazebo window find the sim from another container.
export GZ_PARTITION="${GZ_PARTITION:-yboat_sim}"
