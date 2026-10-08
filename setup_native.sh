#!/usr/bin/env bash
# One-time native install of the BlueBoat sim on Ubuntu 24.04 (native Linux, or WSL2
# on Windows). Installs the same pinned stack as Dockerfile.sim, directly on the
# machine, so Gazebo runs as a normal app on your GPU:
#
#   ROS 2 Jazzy + Gazebo Harmonic (ros-jazzy-ros-gz), MAVROS, ArduPilot SITL
#   (Rover-4.7.1), ardupilot_gazebo, asv_wave_sim, the BlueBoat model, QGroundControl.
#
#   ./setup_native.sh            # ~20-40 min the first time; safe to re-run
#
# Everything outside apt goes in $SIM_DEPS (default ~/blueboat_deps). The script
# finishes by writing $SIM_DEPS/env.sh, which ./start_sim.sh sources.
set -euo pipefail

# Pinned versions -- keep in sync with Dockerfile.sim.
ARDUPILOT_TAG=Rover-4.7.1
ARDUPILOT_GAZEBO_SHA=082a0fe231f6e63bc8d1598f1cba461d9e2ea7f5
ASV_WAVE_SIM_SHA=ca8629df4e191235753dfae92ef725d30b923364
SITL_MODELS_SHA=25bc38ed8c6c0345840159a8cbc0b02781d52f3c
QGC_VERSION=v5.1.4
QGC_SHA256=1c4ac089abfaac6c6fcd75c7b477ea18da1bc3592cddca5ab1a19c1a13410e65

SIM_DEPS="${SIM_DEPS:-${HOME}/blueboat_deps}"
JOBS="${JOBS:-$(nproc)}"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[setup] %s\033[0m\n' "$*" >&2; exit 1; }

# --- Preflight --------------------------------------------------------------
[ "$(id -u)" != "0" ] || die "Run as your normal user, not root (it uses sudo where needed)."
. /etc/os-release
[ "${VERSION_ID:-}" = "24.04" ] || die "Needs Ubuntu 24.04 (ROS 2 Jazzy). This is ${PRETTY_NAME:-unknown}.
  On Windows: in PowerShell run 'wsl --install -d Ubuntu-24.04', then clone the repo there."
[ "$(uname -m)" = "x86_64" ] || die "Only x86_64 is supported for now (QGC and the pinned builds)."
case "$(pwd)" in /mnt/*) die "Clone the repo inside the Linux filesystem (e.g. ~/y_sim), not under /mnt/.";; esac

sudo -v  # ask for the password once, up front
mkdir -p "${SIM_DEPS}"

# Shallow-fetch one exact commit into a directory (no-op if already there).
fetch_sha() {  # <url> <sha> <dir> [sparse paths...]
    local url=$1 sha=$2 dir=$3; shift 3
    if [ -f "${dir}/.pinned" ] && [ "$(cat "${dir}/.pinned")" = "${sha}" ]; then
        echo "  ${dir} already at ${sha:0:10}"; return
    fi
    rm -rf "${dir}" && mkdir -p "${dir}"
    git -C "${dir}" init -q
    git -C "${dir}" remote add origin "${url}"
    if [ "$#" -gt 0 ]; then
        git -C "${dir}" sparse-checkout set "$@"
    fi
    git -C "${dir}" fetch -q --depth 1 origin "${sha}"
    git -C "${dir}" checkout -q FETCH_HEAD
    echo "${sha}" > "${dir}/.pinned"
}

# --- 1. ROS 2 Jazzy apt repository -----------------------------------------
step "ROS 2 apt repository"
if ! dpkg -s ros2-apt-source >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y software-properties-common curl
    sudo add-apt-repository -y universe
    ROS_APT_SOURCE_VERSION=$(curl -fsSL https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
        | grep -F '"tag_name"' | awk -F'"' '{print $4}')
    curl -fsSL -o /tmp/ros2-apt-source.deb \
        "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.${VERSION_CODENAME}_all.deb"
    sudo dpkg -i /tmp/ros2-apt-source.deb
    rm -f /tmp/ros2-apt-source.deb
fi

# --- 2. System packages -----------------------------------------------------
step "System packages (ROS 2 Jazzy desktop, Gazebo Harmonic, MAVROS, build deps)"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ros-jazzy-desktop ros-jazzy-ros-gz ros-jazzy-mavros ros-jazzy-mavros-extras \
    python3-colcon-common-extensions python3-pip git wget mesa-utils xterm iproute2 \
    rapidjson-dev libopencv-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav gstreamer1.0-gl \
    libcgal-dev libfftw3-dev \
    libxcb-xinerama0 libxcb-cursor0 libxkbcommon-x11-0 libpulse0 libgl1

# MAVROS aborts at startup without the GeographicLib geoid datasets.
if [ ! -d /usr/share/GeographicLib/geoids ]; then
    step "GeographicLib datasets for MAVROS"
    sudo bash /opt/ros/jazzy/lib/mavros/install_geographiclib_datasets.sh
fi

# ROS setup scripts reference unset variables.
set +u; source /opt/ros/jazzy/setup.bash; set -u
# Every Gazebo-dependent build below must pick the Harmonic libraries (gz-sim8,
# sdformat14); without this asv_wave_sim looks for Garden's and fails.
export GZ_VERSION=harmonic

# --- 3. ArduPilot SITL -------------------------------------------------------
step "ArduPilot ${ARDUPILOT_TAG} (SITL)"
AP="${SIM_DEPS}/ardupilot"
if [ ! -x "${AP}/build/sitl/bin/ardurover" ]; then
    rm -rf "${AP}"
    git clone -q --depth 1 --shallow-submodules --recurse-submodules --branch "${ARDUPILOT_TAG}" \
        https://github.com/ArduPilot/ardupilot.git "${AP}"
    # Same trims as the Docker image: no wxPython build, no STM32 toolchain.
    ( cd "${AP}" && SKIP_AP_GRAPHIC_ENV=1 DO_AP_STM_ENV=0 SKIP_AP_EXT_ENV=1 SKIP_AP_COV_ENV=1 \
        USER="$(id -un)" Tools/environment_install/install-prereqs-ubuntu.sh -y )
    ( cd "${AP}" && "${HOME}/venv-ardupilot/bin/python3" ./waf configure --board sitl \
        && "${HOME}/venv-ardupilot/bin/python3" ./waf -j"${JOBS}" rover )
else
    echo "  ardurover already built"
fi

# --- 4. ArduPilot Gazebo plugin ---------------------------------------------
step "ardupilot_gazebo plugin"
APG="${SIM_DEPS}/ardupilot_gazebo"
fetch_sha https://github.com/ArduPilot/ardupilot_gazebo.git "${ARDUPILOT_GAZEBO_SHA}" "${APG}"
if [ ! -f "${APG}/build/libArduPilotPlugin.so" ]; then
    # Gazebo comes from the ros-jazzy-gz-*-vendor packages, found via the ROS setup.
    cmake -S "${APG}" -B "${APG}/build" -DCMAKE_BUILD_TYPE=RelWithDebInfo
    cmake --build "${APG}/build" -j"${JOBS}"
fi

# --- 5. BlueBoat model (only the Gazebo models from SITL_Models) ------------
step "BlueBoat model"
fetch_sha https://github.com/ArduPilot/SITL_Models.git "${SITL_MODELS_SHA}" "${SIM_DEPS}/SITL_Models" Gazebo

# --- 6. asv_wave_sim (waves + hydrodynamics) --------------------------------
step "asv_wave_sim"
WS="${SIM_DEPS}/gz_ws"
fetch_sha https://github.com/srmainwaring/asv_wave_sim.git "${ASV_WAVE_SIM_SHA}" "${WS}/src/asv_wave_sim"
if [ ! -f "${WS}/install/lib/libgz-waves1.so" ]; then
    # FindGzOGRE2 looks OGRE-Next up through pkg-config; the vendor package keeps its
    # .pc files off the default path.
    ( cd "${WS}" && PKG_CONFIG_PATH=/opt/ros/jazzy/opt/gz_ogre_next_vendor/lib/pkgconfig \
        colcon build --merge-install --cmake-args \
            -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_TESTING=OFF -DCMAKE_CXX_STANDARD=17 )
fi

# --- 7. QGroundControl -------------------------------------------------------
step "QGroundControl ${QGC_VERSION}"
QGC="${SIM_DEPS}/qgroundcontrol"
if [ ! -x "${QGC}/AppRun" ]; then
    wget -q -O /tmp/QGroundControl.AppImage \
        "https://github.com/mavlink/qgroundcontrol/releases/download/${QGC_VERSION}/QGroundControl-x86_64.AppImage"
    echo "${QGC_SHA256}  /tmp/QGroundControl.AppImage" | sha256sum -c -
    chmod +x /tmp/QGroundControl.AppImage
    # Extract instead of FUSE-mounting: WSL often lacks FUSE.
    ( cd "${SIM_DEPS}" && rm -rf squashfs-root && /tmp/QGroundControl.AppImage --appimage-extract >/dev/null \
        && rm -rf "${QGC}" && mv squashfs-root "${QGC}" )
    rm -f /tmp/QGroundControl.AppImage
fi
mkdir -p "${SIM_DEPS}/bin"
printf '#!/usr/bin/env bash\nexec "%s/AppRun" "$@"\n' "${QGC}" > "${SIM_DEPS}/bin/qgroundcontrol"
chmod +x "${SIM_DEPS}/bin/qgroundcontrol"

# --- 8. Environment ----------------------------------------------------------
step "Writing ${SIM_DEPS}/env.sh"
cat > "${SIM_DEPS}/env.sh" <<EOF
# Generated by setup_native.sh -- sourced by start_sim.sh. Re-run setup to regenerate.
export SIM_DEPS="${SIM_DEPS}"
export ARDUPILOT_DIR="${AP}"
export GZ_VERSION=harmonic
export GZ_SIM_SYSTEM_PLUGIN_PATH="${APG}/build:${WS}/install/lib\${GZ_SIM_SYSTEM_PLUGIN_PATH:+:\${GZ_SIM_SYSTEM_PLUGIN_PATH}}"
export GZ_SIM_RESOURCE_PATH="${APG}/models:${APG}/worlds:${SIM_DEPS}/SITL_Models/Gazebo/models:${SIM_DEPS}/SITL_Models/Gazebo/worlds:${WS}/src/asv_wave_sim/gz-waves-models/models:${WS}/src/asv_wave_sim/gz-waves-models/world_models:${WS}/src/asv_wave_sim/gz-waves-models/worlds\${GZ_SIM_RESOURCE_PATH:+:\${GZ_SIM_RESOURCE_PATH}}"
export LD_LIBRARY_PATH="${WS}/install/lib\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
# sim_vehicle.py from ArduPilot; MAVProxy from its venv. Appended, so the venv's python3
# never shadows the system one that has rclpy.
export PATH="${SIM_DEPS}/bin:${AP}/Tools/autotest:\${PATH}:${HOME}/venv-ardupilot/bin"
EOF

step "Done"
cat <<EOF
Everything is installed under ${SIM_DEPS}.

Start the sim:      ./start_sim.sh
Check the GPU:      glxinfo -B | grep "renderer string"
                    (should name your GPU, not "llvmpipe")
EOF
