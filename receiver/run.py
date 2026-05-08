import csv
import json
import math
import time
import argparse
import subprocess
from pathlib import Path

from pubsub import pub

import meshtastic.serial_interface
import meshtastic.tcp_interface


def connect(args):
    if args.host:
        return meshtastic.tcp_interface.TCPInterface(hostname=args.host, noProto=False)

    if args.port:
        return meshtastic.serial_interface.SerialInterface(devPath=args.port)

    return meshtastic.serial_interface.SerialInterface()


def get_field(packet, *names):
    for name in names:
        if name in packet:
            return packet[name]
    return None


def parse_test_text(text):
    if not text or not text.startswith("RT,"):
        return None

    result = {}

    for part in text.split(",")[1:]:
        if "=" in part:
            key, value = part.split("=", 1)
            result[key.strip()] = value.strip()

    required_fields = ["run", "seq", "tx_ms"]

    for field in required_fields:
        if field not in result:
            return None

    return result


def haversine_m(lat1, lon1, lat2, lon2):
    radius_m = 6371000

    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)

    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lon2 - lon1)

    a = (
        math.sin(d_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    )

    return 2 * radius_m * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def get_termux_location():
    try:
        out = subprocess.check_output(
            ["termux-location", "-p", "gps", "-r", "last"],
            timeout=5
        )

        data = json.loads(out.decode("utf-8"))

        return {
            "lat": data.get("latitude"),
            "lon": data.get("longitude"),
            "accuracy": data.get("accuracy"),
        }

    except Exception:
        return {
            "lat": None,
            "lon": None,
            "accuracy": None,
        }


parser = argparse.ArgumentParser()

parser.add_argument("--port", help="Например /dev/ttyUSB0")
parser.add_argument("--host", help="IP Meshtastic-устройства по Wi-Fi")
parser.add_argument("--out", default="meshtastic_experiment.csv")

parser.add_argument("--sender-lat", type=float, required=True)
parser.add_argument("--sender-lon", type=float, required=True)

parser.add_argument("--use-termux-gps", action="store_true")

args = parser.parse_args()

out_path = Path(args.out)

fields = [
    "local_log_time_ms",
    "run_id",
    "seq",
    "from",
    "to",
    "packet_id",

    "tx_time_ms",
    "rx_time_s",
    "rx_time_ms_wall",
    "delay_ms_wall",

    "rssi",
    "snr",

    "sender_lat",
    "sender_lon",
    "receiver_lat",
    "receiver_lon",
    "gps_accuracy_m",
    "distance_m",

    "hop_start",
    "hop_limit",
    "hops_taken",

    "text",
]

if not out_path.exists():
    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()


def on_receive(packet, interface):
    decoded = packet.get("decoded", {})

    text = decoded.get("text")

    print(text)

    if text is None:
        payload = decoded.get("payload")

        if isinstance(payload, bytes):
            text = payload.decode("utf-8", errors="replace")

    parsed = parse_test_text(text)

    if parsed is None:
        return

    now_ms = int(time.time() * 1000)

    tx_time_ms = int(parsed["tx_ms"])

    gps = (
        get_termux_location()
        if args.use_termux_gps
        else {
            "lat": None,
            "lon": None,
            "accuracy": None,
        }
    )

    distance_m = None

    if gps["lat"] is not None and gps["lon"] is not None:
        distance_m = haversine_m(
            args.sender_lat,
            args.sender_lon,
            gps["lat"],
            gps["lon"]
        )

    hop_start = get_field(packet, "hopStart", "hop_start")
    hop_limit = get_field(packet, "hopLimit", "hop_limit")

    hops_taken = None

    if hop_start is not None and hop_limit is not None:
        hops_taken = int(hop_start) - int(hop_limit)

    row = {
        "local_log_time_ms": now_ms,

        "run_id": parsed["run"],
        "seq": parsed["seq"],

        "from": get_field(packet, "from"),
        "to": get_field(packet, "to"),
        "packet_id": get_field(packet, "id"),

        "tx_time_ms": tx_time_ms,
        "rx_time_s": get_field(packet, "rxTime", "rx_time"),
        "rx_time_ms_wall": now_ms,
        "delay_ms_wall": now_ms - tx_time_ms,

        "rssi": get_field(packet, "rxRssi", "rx_rssi"),
        "snr": get_field(packet, "rxSnr", "rx_snr"),

        "sender_lat": args.sender_lat,
        "sender_lon": args.sender_lon,

        "receiver_lat": gps["lat"],
        "receiver_lon": gps["lon"],
        "gps_accuracy_m": gps["accuracy"],
        "distance_m": distance_m,

        "hop_start": hop_start,
        "hop_limit": hop_limit,
        "hops_taken": hops_taken,

        "text": text,
    }

    with out_path.open("a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writerow(row)

    print(row)


pub.subscribe(on_receive, "meshtastic.receive")

interface = connect(args)

try:
    while True:
        time.sleep(1)

except KeyboardInterrupt:
    interface.close()
