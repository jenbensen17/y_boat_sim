FROM osrf/ros:jazzy-desktop-full
RUN apt-get update && apt-get install -y ros-jazzy-ros-gz \
    && rm -rf /var/lib/apt/lists/*
RUN echo "source /opt/ros/jazzy/setup.bash" >> /root/.bashrc
CMD ["gz", "sim", "-s", "-r", "shapes.sdf"]