#!/usr/bin/env python3
"""BlueBoat sim launcher. Works the same on Windows, macOS and Linux; needs only Docker
and Python 3.

    python sim.py start     start the sim: Gazebo in your browser, QGroundControl and
                            the ArduPilot console as windows on your desktop
    python sim.py console   reopen the ArduPilot console in this terminal
    python sim.py stop      stop it
    python sim.py status    is it running, and how is it rendering
    python sim.py test      ROS 2 drive test against the running sim
    python sim.py logs      follow the sim's output
    python sim.py shell     bash shell inside the sim

Options for start:  --cpu (skip the GPU)   --no-gazebo   --no-qgc   --no-console   --no-browser
                    --world PATH   (a world file inside this repo, e.g. sim/blueboat_waves.sdf)
"""
import argparse
import glob
import os
import platform
import shutil
import subprocess
import sys
import time
import webbrowser

REPO = os.path.dirname(os.path.abspath(__file__))
CONTAINER = "y_boat_sim"
IMAGE = "y_boat_sim_desktop:local"
DESKTOP_URL = "http://localhost:6080/vnc.html?autoconnect=1&resize=scale"
GPU_FILE = "compose.gpu-wsl.yaml"
STATE_FILE = os.path.join(REPO, ".sim_mode")  # remembers which compose files are in use
CONSOLE_CMD = ["docker", "exec", "-it", CONTAINER, "tmux", "attach", "-t", "ardupilot"]
QGC_DOWNLOAD = ("https://docs.qgroundcontrol.com/master/en/qgc-user-guide/"
                "getting_started/download_and_install.html")
IS_WSL = platform.system() == "Linux" and "microsoft" in platform.release().lower()


# --- QGroundControl and the ArduPilot console on the host ---------------------

def find_qgc():
    """Path (or command) of a QGroundControl installed on this machine, or None."""
    system = platform.system()
    if system == "Darwin":
        app = "/Applications/QGroundControl.app"
        return app if os.path.isdir(app) else None
    if system == "Windows" or IS_WSL:
        roots = ["C:\\Program Files", "C:\\Program Files (x86)"] if system == "Windows" \
            else ["/mnt/c/Program Files", "/mnt/c/Program Files (x86)"]
        for root in roots:
            exe = os.path.join(root, "QGroundControl", "bin", "QGroundControl.exe")
            if os.path.isfile(exe):
                return exe
        return None
    found = shutil.which("QGroundControl") or shutil.which("qgroundcontrol")
    if found:
        return found
    images = sorted(glob.glob(os.path.expanduser("~/*QGroundControl*.AppImage"))
                    + glob.glob(os.path.expanduser("~/Applications/*QGroundControl*.AppImage")))
    return images[-1] if images else None


def qgc_running():
    if platform.system() == "Windows" or IS_WSL:
        tasklist = "tasklist" if platform.system() == "Windows" else "tasklist.exe"
        out = run([tasklist, "/FI", "IMAGENAME eq QGroundControl.exe"], check=False,
                  capture=True).stdout or ""
        return "QGroundControl.exe" in out
    return run(["pgrep", "-if", "qgroundcontrol"], check=False, quiet=True).returncode == 0


def launch_qgc():
    if qgc_running():
        say("QGroundControl is already open; it picks the boat up by itself.")
        return
    qgc = find_qgc()
    if not qgc:
        say("QGroundControl isn't installed on this machine. Install it to see the boat on "
            f"the map (it connects by itself): {QGC_DOWNLOAD}")
        return
    if platform.system() == "Darwin":
        subprocess.Popen(["open", "-a", qgc])
    else:
        subprocess.Popen([qgc], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    say("Opened QGroundControl (it connects to the sim by itself over UDP 14550).")


def open_console_window():
    """Open the ArduPilot console in a new terminal window, if this OS lets us."""
    system = platform.system()
    title = "ArduPilot (MAVProxy)"
    tries = []
    if system == "Windows":
        tries = [["wt.exe", "-w", "new", "--title", title, *CONSOLE_CMD],
                 ["cmd.exe", "/c", "start", title, *CONSOLE_CMD]]
    elif IS_WSL:
        distro = os.environ.get("WSL_DISTRO_NAME", "")
        inner = ["wsl.exe", *(["-d", distro] if distro else []), "--", *CONSOLE_CMD]
        tries = [["wt.exe", "-w", "new", "--title", title, *inner],
                 ["cmd.exe", "/c", "start", title, *inner]]
    elif system == "Darwin":
        script = f'tell application "Terminal" to do script "{" ".join(CONSOLE_CMD)}"'
        tries = [["osascript", "-e", script, "-e", 'tell application "Terminal" to activate']]
    else:
        for term, flag in [("x-terminal-emulator", "-e"), ("gnome-terminal", "--"),
                           ("konsole", "-e"), ("xfce4-terminal", "-x"), ("xterm", "-e")]:
            tries.append([term, flag, *CONSOLE_CMD])
    for cmd in tries:
        if not shutil.which(cmd[0]):
            continue
        try:
            subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True, cwd=REPO if not IS_WSL else "/")
            say("Opened the ArduPilot console in a new terminal window.")
            return
        except OSError:
            continue
    say("Open the ArduPilot console in another terminal with: python sim.py console")


def say(msg):
    print(f"[sim] {msg}", flush=True)


def run(cmd, check=True, capture=False, quiet=False):
    kw = {"cwd": REPO, "text": True}
    if capture:
        kw.update(stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    elif quiet:
        kw.update(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    result = subprocess.run(cmd, **kw)
    if check and result.returncode != 0:
        if capture:
            print(result.stdout)
        sys.exit(f"[sim] Command failed: {' '.join(cmd)}")
    return result


def compose(files, *args, **kw):
    cmd = ["docker", "compose"]
    for f in files:
        cmd += ["-f", f]
    return run(cmd + list(args), **kw)


def check_docker():
    if not shutil.which("docker"):
        sys.exit("[sim] Docker isn't installed. Get Docker Desktop (Windows/macOS) or Docker "
                 "Engine (Linux): https://docs.docker.com/get-docker/")
    if run(["docker", "info"], check=False, quiet=True).returncode != 0:
        sys.exit("[sim] Docker isn't running. Start Docker Desktop (or the docker service) "
                 "and try again.")


def build_image(files):
    if run(["docker", "image", "inspect", IMAGE], check=False, quiet=True).returncode != 0:
        say("First run: downloading and building the sim image (several GB, once)...")
        compose(files, "build")
    else:
        # Picks up changes to docker/desktop.Dockerfile; seconds when nothing changed.
        compose(files, "build", "--quiet", quiet=True)


def gpu_works():
    """True if the container can render through Windows' DirectX bridge (/dev/dxg).

    That's every Windows machine running Docker Desktop or Docker in WSL2, as long as
    the Windows GPU driver works. Checked for real (a broken driver crashes GL apps)
    by rendering one frame's worth of glxinfo on a throwaway virtual display.
    """
    probe = ("Xvfb :9 -screen 0 64x64x24 >/dev/null 2>&1 & sleep 1; "
             "DISPLAY=:9 glxinfo -B 2>/dev/null | grep -o 'renderer string:.*'")
    cmd = ["docker", "run", "--rm", "--platform", "linux/amd64",
           "--device", "/dev/dxg", "-v", "/usr/lib/wsl:/usr/lib/wsl:ro",
           "-e", "GALLIUM_DRIVER=d3d12", "-e", "LD_LIBRARY_PATH=/usr/lib/wsl/lib",
           "--entrypoint", "bash", IMAGE, "-c", probe]
    out = run(cmd, check=False, capture=True).stdout or ""
    return "D3D12" in out, out.strip().replace("renderer string: ", "")


def wait_until_ready(timeout=180):
    say("Waiting for the sim to come up...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        logs = run(["docker", "logs", CONTAINER], check=False, capture=True).stdout or ""
        if "Simulator is READY" in logs:
            return True
        state = run(["docker", "inspect", "-f", "{{.State.Running}}", CONTAINER],
                    check=False, capture=True).stdout.strip()
        if state != "true":
            print(logs[-3000:])
            sys.exit("[sim] The sim container stopped. Its output is above.")
        time.sleep(2)
    sys.exit("[sim] Timed out waiting for the sim. Check: python sim.py logs")


def saved_files():
    try:
        with open(STATE_FILE) as f:
            return f.read().split()
    except OSError:
        return ["compose.yaml"]


def cmd_start(args):
    check_docker()
    files = ["compose.yaml"]
    build_image(files)
    if run(["docker", "ps", "-q", "-f", f"name=^{CONTAINER}$"], capture=True).stdout.strip():
        say("Already running; restarting it.")
        compose(saved_files(), "down", quiet=True)

    env = os.environ.copy()
    if args.cpu:
        gpu, renderer = False, "skipped (--cpu)"
    else:
        gpu, renderer = gpu_works()
    if gpu:
        files.append(GPU_FILE)
        say(f"Rendering on your GPU: {renderer}")
    else:
        env["GZ_GUI_ARGS"] = "--render-engine-gui ogre"
        say("Rendering on the CPU (no usable GPU in containers on this machine). "
            "Gazebo will be choppy (~10 FPS) and can slow the physics; if it does, "
            "use --no-gazebo and follow the boat in QGroundControl.")
    if args.no_gazebo:
        env["GZ_GUI"] = "0"
    if args.world:
        env["WORLD"] = "/home/simuser/sim_scratch/" + args.world.replace("\\", "/").lstrip("./")

    cmd = ["docker", "compose"]
    for f in files:
        cmd += ["-f", f]
    if subprocess.run(cmd + ["up", "-d"], cwd=REPO, env=env).returncode != 0:
        sys.exit("[sim] docker compose up failed (output above).")
    with open(STATE_FILE, "w") as f:
        f.write(" ".join(files))

    wait_until_ready()
    say("Ready.")
    if not args.no_qgc:
        launch_qgc()
    if not args.no_console:
        open_console_window()
    if not args.no_gazebo:
        say(f"Gazebo: {DESKTOP_URL}")
        if not args.no_browser:
            webbrowser.open(DESKTOP_URL)
    say("ArduPilot console: python sim.py console    Drive test: python sim.py test    "
        "Stop: python sim.py stop")


def cmd_stop(_):
    check_docker()
    compose(saved_files(), "down")
    say("Stopped.")


def cmd_status(_):
    check_docker()
    running = run(["docker", "ps", "-q", "-f", f"name=^{CONTAINER}$"], capture=True).stdout.strip()
    if not running:
        say("Not running. Start it with: python sim.py start")
        return
    gpu = GPU_FILE in saved_files()
    say(f"Running ({'GPU' if gpu else 'CPU'} rendering). Desktop: {DESKTOP_URL}")


def exec_in_sim(bash_cmd, interactive=False):
    check_docker()
    if not run(["docker", "ps", "-q", "-f", f"name=^{CONTAINER}$"], capture=True).stdout.strip():
        sys.exit("[sim] The sim isn't running. Start it with: python sim.py start")
    flags = ["-it"] if interactive and sys.stdin.isatty() else ["-i"]
    return subprocess.run(["docker", "exec", *flags, CONTAINER, "bash", "-c", bash_cmd]).returncode


def cmd_console(_):
    say("ArduPilot console. Detach with Ctrl+B then D (the sim keeps running).")
    sys.exit(exec_in_sim("exec tmux attach -t ardupilot", interactive=True))


def cmd_test(_):
    sys.exit(exec_in_sim("/home/simuser/sim_scratch/test_ros.sh"))


def cmd_shell(_):
    sys.exit(exec_in_sim("source /opt/ros/jazzy/setup.bash; exec bash", interactive=True))


def cmd_logs(_):
    check_docker()
    subprocess.run(["docker", "logs", "-f", CONTAINER])


def main():
    p = argparse.ArgumentParser(description="BlueBoat sim launcher",
                                formatter_class=argparse.RawDescriptionHelpFormatter,
                                epilog=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("start", help="start the sim")
    s.add_argument("--cpu", action="store_true", help="render on the CPU even if a GPU works")
    s.add_argument("--no-gazebo", action="store_true", help="no Gazebo window (physics still runs)")
    s.add_argument("--no-qgc", action="store_true", help="don't open QGroundControl")
    s.add_argument("--no-console", action="store_true",
                   help="don't open the ArduPilot console window")
    s.add_argument("--no-browser", action="store_true", help="don't open the browser")
    s.add_argument("--world", help="world file in this repo, e.g. sim/blueboat_waves.sdf")
    s.set_defaults(func=cmd_start)
    for name, fn, help_ in [("stop", cmd_stop, "stop the sim"),
                            ("status", cmd_status, "show whether it's running"),
                            ("console", cmd_console, "show the ArduPilot console here"),
                            ("test", cmd_test, "run the ROS 2 drive test"),
                            ("logs", cmd_logs, "follow the sim's output"),
                            ("shell", cmd_shell, "open a shell in the sim")]:
        sub.add_parser(name, help=help_).set_defaults(func=fn)
    args = p.parse_args()
    if platform.system() == "Windows" and os.path.abspath(REPO).startswith("\\\\wsl"):
        say("Tip: running from a WSL terminal is faster than PowerShell on a \\\\wsl path.")
    args.func(args)


if __name__ == "__main__":
    main()
