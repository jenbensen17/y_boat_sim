# Platform Setup & Per-OS Guides

`run_sim.sh` detects your OS, GPU and display automatically, so most people need
nothing on this page beyond the prerequisites. The rest is here for when the
defaults need help.

---

# Prerequisites by Operating System

## 1. Linux (Native)
- **Docker**: Docker Engine 24.0+ (`sudo apt install docker.io` or official Docker repository).
- **Docker Permissions**: Ensure your user is in the docker group: `sudo usermod -aG docker $USER` (log out and back in).
- **GPU Driver**:
  - *NVIDIA*: Install NVIDIA drivers and `nvidia-container-toolkit` (`sudo apt install nvidia-container-toolkit`).
  - *Intel / AMD*: Works out of the box via `/dev/dri`.
  - *No GPU*: Falls back automatically to CPU software rendering.

## 2. Windows 10/11 (WSL2)
- **WSL2 with WSLg** (standard on Windows 11 and updated Windows 10). Run `wsl --update` from PowerShell if needed.
- **NVIDIA GPU Driver for Windows**: Install the regular Windows NVIDIA driver from nvidia.com. *Do not install Linux display drivers inside WSL2* (Windows forwards GPU acceleration automatically via DirectX `/dev/dxg`).
- **Docker Desktop for Windows**:
  1. Open Docker Desktop **Settings -> General** $\rightarrow$ verify *"Use the WSL 2 based engine"* is checked.
  2. Open **Settings -> Resources -> WSL Integration** $\rightarrow$ turn on integration for your Ubuntu/Linux distro.

## 3. macOS (Apple Silicon M1–M4 & Intel)
- **Docker Desktop for Mac**: Installed and running.
- **Apple Silicon (M1/M2/M3/M4)**: In Docker Desktop **Settings -> General**, ensure *"Use Rosetta for x86/amd64 emulation on Apple Silicon"* is checked.
- **Optional Native GCS**: Download [QGroundControl v5.1.4 for macOS (.dmg)](https://github.com/mavlink/qgroundcontrol/releases/download/v5.1.4/QGroundControl.dmg).

---

---

# Per-Platform Notes

## Windows WSL2 Setup Details
1. **WSLg (GUI)**: Windows 11 and updated Windows 10 include WSLg, which automatically renders X11 and Wayland windows directly on the Windows desktop with hardware acceleration.
2. **GPU Acceleration**: The launcher automatically detects `/dev/dxg` and passes it to Docker. DirectX 12 hardware acceleration is enabled without any configuration.
3. **Troubleshooting WSLg Display**: If windows do not appear, open PowerShell and update WSL:
   ```powershell
   wsl --update
   wsl --shutdown
   ```
   Then reopen your WSL terminal and relaunch `./run_sim.sh`.

---

## macOS Workflows

### Workflow 1: Headless Sim + Native macOS QGroundControl *(Recommended for Mac)*
This gives the fastest performance and full Apple Metal 60 FPS GPU rendering on Retina displays:
1. Start the simulation in headless mode:
   ```bash
   HEADLESS=1 ./run_sim.sh
   ```
2. Download [QGroundControl v5.1.4 for macOS (.dmg)](https://github.com/mavlink/qgroundcontrol/releases/download/v5.1.4/QGroundControl.dmg), install it to `/Applications`, and open it. It auto-connects to the simulator on `127.0.0.1:14550`.
3. In a second terminal, verify with `./test_ros.sh`.

### Workflow 2: Full 3-Window GUI via XQuartz
To see the 3D Gazebo window on macOS:
1. Install XQuartz: `brew install --cask xquartz`.
2. Open XQuartz $\rightarrow$ **Settings -> Security** $\rightarrow$ check **"Allow connections from network clients"**.
3. In Mac terminal: `xhost + 127.0.0.1`.
4. Run `./run_sim.sh`. The launcher routes display traffic to `host.docker.internal:0` automatically.

---

## Headless / Cloud / CI Mode
If running on a remote cloud server (AWS, GCP), via SSH without X11 forwarding, or in a GitHub Actions runner:

```bash
HEADLESS=1 ./run_sim.sh
```

The script automatically detects an empty `$DISPLAY` environment variable and falls back to headless mode. Gazebo physics, ArduPilot SITL, and all ROS 2 topics run at full speed.

---
