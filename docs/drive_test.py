#!/usr/bin/env python3
"""BlueBoat SITL drive tests: MANUAL, arming-with-checks, AUTO mission, GUIDED target.

Talks MAVLink directly (pymavlink) instead of scraping the MAVProxy console, so it works
with the HEADLESS launch path where MAVProxy runs with --daemon and has no console.

Connects to SERIAL1 (tcp:5762) so it does not disturb MAVProxy on SERIAL0 (tcp:5760).

Usage:  python3 drive_test.py [connection_string]
"""
import math
import sys
import time

from pymavlink import mavutil

CONN = sys.argv[1] if len(sys.argv) > 1 else "tcp:127.0.0.1:5762"

# Must match HOME_LOCATION in launch_blueboat.sh and <spherical_coordinates> in
# blueboat_waves.sdf. Open water on Utah Lake.
HOME_LAT, HOME_LON = 40.2386, -111.8000
# ~25 m square around home.
DLAT = 25.0 / 111320.0
DLON = 25.0 / (111320.0 * math.cos(math.radians(HOME_LAT)))
WAYPOINTS = [
    (HOME_LAT + DLAT, HOME_LON),
    (HOME_LAT + DLAT, HOME_LON + DLON),
    (HOME_LAT, HOME_LON + DLON),
    (HOME_LAT, HOME_LON),
]


def log(msg):
    print(msg, flush=True)


def pos(m):
    """Latest global position as (lat, lon) in degrees, or None."""
    msg = m.recv_match(type="GLOBAL_POSITION_INT", blocking=True, timeout=5)
    if not msg:
        return None
    return msg.lat / 1e7, msg.lon / 1e7


def pos_nonblocking(m):
    msg = m.recv_match(type="GLOBAL_POSITION_INT", blocking=False)
    if not msg:
        return None
    return round(msg.lat / 1e7, 7), round(msg.lon / 1e7, 7)


def dist_m(a, b):
    dlat = (b[0] - a[0]) * 111320.0
    dlon = (b[1] - a[1]) * 111320.0 * math.cos(math.radians(a[0]))
    return math.hypot(dlat, dlon)


def wait_gps(m, timeout=120):
    log("[wait] GPS 3D fix + EKF...")
    t0 = time.time()
    while time.time() - t0 < timeout:
        msg = m.recv_match(type="GPS_RAW_INT", blocking=True, timeout=5)
        if msg and msg.fix_type >= 3:
            log(f"[wait] GPS fix_type={msg.fix_type}, sats={msg.satellites_visible}")
            return True
    return False


def set_mode(m, mode):
    m.set_mode(mode)
    t0 = time.time()
    while time.time() - t0 < 10:
        msg = m.recv_match(type="HEARTBEAT", blocking=True, timeout=3)
        if msg:
            cur = mavutil.mode_string_v10(msg)
            if cur == mode:
                log(f"[mode] now {cur}")
                return True
    log(f"[mode] FAILED to enter {mode}")
    return False


def arm(m):
    m.mav.command_long_send(
        m.target_system, m.target_component,
        mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM, 0, 1, 0, 0, 0, 0, 0, 0)
    msg = m.recv_match(type="COMMAND_ACK", blocking=True, timeout=10)
    if msg and msg.result == 0:
        log("[arm] ARMED (accepted)")
        return True
    log(f"[arm] REJECTED: result={getattr(msg, 'result', 'no ack')}")
    return False


def statustexts(m, n=6):
    out = []
    while len(out) < n:
        msg = m.recv_match(type="STATUSTEXT", blocking=False)
        if not msg:
            break
        out.append(msg.text)
    return out


def test_manual(m):
    log("\n=== MANUAL throttle test ===")
    if not set_mode(m, "MANUAL"):
        return
    if not arm(m):
        return
    start = pos(m)
    log(f"[manual] start {start}")
    # RC3 = throttle on a skid-steer rover. ArduPilot times out an RC override after
    # ~1 s, and MAVProxy on SERIAL0 is also talking, so send at ~10 Hz to keep it latched.
    for _ in range(120):
        m.mav.rc_channels_override_send(m.target_system, m.target_component,
                                        1500, 0, 1900, 0, 0, 0, 0, 0)
        time.sleep(0.1)
    end = pos(m)
    # release override
    m.mav.rc_channels_override_send(m.target_system, m.target_component,
                                    0, 0, 0, 0, 0, 0, 0, 0)
    log(f"[manual] end   {end}")
    if start and end:
        log(f"[manual] travelled {dist_m(start, end):.1f} m in ~12 s")


def upload_mission(m):
    log("\n=== AUTO mission upload ===")
    n = len(WAYPOINTS) + 1
    m.mav.mission_count_send(m.target_system, m.target_component, n,
                             mavutil.mavlink.MAV_MISSION_TYPE_MISSION)
    for _ in range(n * 3):
        req = m.recv_match(type=["MISSION_REQUEST", "MISSION_REQUEST_INT"],
                           blocking=True, timeout=10)
        if not req:
            break
        i = req.seq
        if i == 0:
            lat, lon, cmd = HOME_LAT, HOME_LON, mavutil.mavlink.MAV_CMD_NAV_WAYPOINT
        else:
            lat, lon = WAYPOINTS[i - 1]
            cmd = mavutil.mavlink.MAV_CMD_NAV_WAYPOINT
        m.mav.mission_item_int_send(
            m.target_system, m.target_component, i,
            mavutil.mavlink.MAV_FRAME_GLOBAL_RELATIVE_ALT, cmd,
            0, 1, 0, 2, 0, 0, int(lat * 1e7), int(lon * 1e7), 0,
            mavutil.mavlink.MAV_MISSION_TYPE_MISSION)
        ack = m.recv_match(type="MISSION_ACK", blocking=False)
        if ack:
            log(f"[mission] ack type={ack.type}")
            break
    log(f"[mission] uploaded {n} items (home + {len(WAYPOINTS)} waypoints)")


def test_auto(m, duration=240):
    log("\n=== AUTO mission run ===")
    # Rewind to the first waypoint. Without this the mission counter can still be at the
    # end of a previous run, so AUTO "completes" instantly and reports a single
    # meaningless cross-track sample.
    m.mav.mission_set_current_send(m.target_system, m.target_component, 1)
    time.sleep(2)
    cur = m.recv_match(type="MISSION_CURRENT", blocking=True, timeout=5)
    log(f"[auto] starting at waypoint {getattr(cur, 'seq', '?')}")
    if not set_mode(m, "AUTO"):
        return
    arm(m)
    t0 = time.time()
    last_seq = -1
    xtracks = []
    while time.time() - t0 < duration:
        msg = m.recv_match(type=["MISSION_CURRENT", "NAV_CONTROLLER_OUTPUT",
                                 "GLOBAL_POSITION_INT"], blocking=True, timeout=5)
        if not msg:
            continue
        if msg.get_type() == "MISSION_CURRENT" and msg.seq != last_seq:
            p = pos_nonblocking(m)
            last_seq = msg.seq
            log(f"[auto] t={time.time()-t0:5.0f}s  now heading to waypoint {msg.seq}"
                + (f"  at {p}" if p else ""))
            # Only treat the last waypoint as "done" once we have actually driven for a
            # while, so a stale mission counter cannot end the test immediately.
            if msg.seq >= len(WAYPOINTS) and time.time() - t0 > 20:
                log("[auto] final waypoint reached")
                break
        elif msg.get_type() == "NAV_CONTROLLER_OUTPUT":
            xtracks.append(abs(msg.xtrack_error))
    if xtracks:
        log(f"[auto] cross-track error: mean={sum(xtracks)/len(xtracks):.2f} m  "
            f"max={max(xtracks):.2f} m  samples={len(xtracks)}")


def test_guided(m):
    log("\n=== GUIDED position target ===")
    if not set_mode(m, "GUIDED"):
        return
    arm(m)
    target = (HOME_LAT + 2 * DLAT, HOME_LON)  # ~50 m north of home
    log(f"[guided] target {target}")
    m.mav.set_position_target_global_int_send(
        0, m.target_system, m.target_component,
        mavutil.mavlink.MAV_FRAME_GLOBAL_RELATIVE_ALT_INT,
        0b110111111000, int(target[0] * 1e7), int(target[1] * 1e7), 0,
        0, 0, 0, 0, 0, 0, 0, 0)
    t0 = time.time()
    best = None
    while time.time() - t0 < 180:
        p = pos(m)
        if not p:
            continue
        d = dist_m(p, target)
        best = d if best is None else min(best, d)
        if int(time.time() - t0) % 20 == 0:
            log(f"[guided] t={time.time()-t0:5.0f}s  {d:6.1f} m to target")
        if d < 5.0:
            log(f"[guided] ARRIVED within {d:.1f} m")
            return
        time.sleep(1)
    log(f"[guided] closest approach {best:.1f} m")


def main():
    log(f"[conn] connecting to {CONN}")
    m = mavutil.mavlink_connection(CONN)
    m.wait_heartbeat()
    log(f"[conn] heartbeat from system {m.target_system} component {m.target_component}")
    if not wait_gps(m):
        log("[conn] no GPS fix, aborting")
        return 1
    time.sleep(5)
    for t in statustexts(m, 10):
        log(f"[status] {t}")
    test_manual(m)
    upload_mission(m)
    test_auto(m)
    test_guided(m)
    log("\n=== done ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
