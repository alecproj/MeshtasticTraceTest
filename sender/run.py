import time
import argparse

import meshtastic.serial_interface
import meshtastic.tcp_interface


def connect(args):
    if args.host:
        return meshtastic.tcp_interface.TCPInterface(hostname=args.host, noProto=False)

    if args.port:
        return meshtastic.serial_interface.SerialInterface(devPath=args.port)

    return meshtastic.serial_interface.SerialInterface()


parser = argparse.ArgumentParser()

parser.add_argument("--port", help="Например /dev/ttyUSB0")
parser.add_argument("--host", help="IP Meshtastic-устройства по Wi-Fi")
parser.add_argument("--dest", required=True, help="Node ID получателя, например !28979058")
parser.add_argument("--ack", action="store_true")
parser.add_argument("--interval", type=float, default=60.0)
parser.add_argument("--run-id", default="test01")

args = parser.parse_args()

interface = connect(args)

seq = 0

try:
    while True:
        tx_time_ms = int(time.time() * 1000)

        text = (
            f"RT,"
            f"run={args.run_id},"
            f"seq={seq},"
            f"tx_ms={tx_time_ms}"
        )

        interface.sendText(
            text,
            destinationId=args.dest,
            wantAck=args.ack
        )

        print(text)

        seq += 1
        time.sleep(args.interval)

except KeyboardInterrupt:
    interface.close()
