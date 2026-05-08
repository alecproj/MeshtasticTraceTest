#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VENV_DIR="$ROOT_DIR/.venv"
PYTHON_BIN="$VENV_DIR/bin/python"
PIP_BIN="$VENV_DIR/bin/pip"

SENDER_SCRIPT="$ROOT_DIR/sender/run.py"
RECEIVER_SCRIPT="$ROOT_DIR/receiver/run.py"


print_header() {
    clear
    echo "========================================"
    echo " Meshtastic Trace Test Service"
    echo "========================================"
    echo
}

pause() {
    echo
    read -r -p "Press Enter to continue..."
}

die() {
    echo
    echo "Error: $1"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

run_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command_exists sudo; then
        sudo "$@"
    else
        die "sudo is not installed. Run this command as root or install sudo."
    fi
}

ask() {
    local prompt="$1"
    local default="${2:-}"
    local value

    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " value
        echo "${value:-$default}"
    else
        read -r -p "$prompt: " value
        echo "$value"
    fi
}

ask_required() {
    local prompt="$1"
    local value=""

    while [[ -z "$value" ]]; do
        read -r -p "$prompt: " value
        if [[ -z "$value" ]]; then
            echo "Value cannot be empty."
        fi
    done

    echo "$value"
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local value

    while true; do
        read -r -p "$prompt [$default]: " value
        value="${value:-$default}"

        case "$value" in
            y|Y|yes|YES|Yes)
                return 0
                ;;
            n|N|no|NO|No)
                return 1
                ;;
            *)
                echo "Enter y or n."
                ;;
        esac
    done
}

ensure_project_structure() {
    [[ -f "$SENDER_SCRIPT" ]] || die "Sender script not found: $SENDER_SCRIPT"
    [[ -f "$RECEIVER_SCRIPT" ]] || die "Receiver script not found: $RECEIVER_SCRIPT"
}

create_venv_and_install_python_deps() {
    local python_cmd="$1"

    echo
    echo "Creating virtual environment: $VENV_DIR"

    "$python_cmd" -m venv "$VENV_DIR"

    echo
    echo "Upgrading pip..."
    "$PYTHON_BIN" -m pip install --upgrade pip wheel

    echo
    echo "Installing Python dependencies..."
    "$PIP_BIN" install "meshtastic[cli]" pypubsub

    echo
    echo "Installation completed."
}

install_termux() {
    echo
    echo "Installing dependencies for Termux..."

    command_exists pkg || die "pkg command not found. Are you running this inside Termux?"

    pkg update -y
    pkg install -y python termux-api

    if ! command_exists termux-location; then
        echo
        echo "Warning: termux-location command was not found."
        echo "Install Termux:API app and package, then grant location permission."
    fi

    create_venv_and_install_python_deps "python"
}

install_arch() {
    echo
    echo "Installing dependencies for Arch Linux..."

    command_exists pacman || die "pacman not found. This does not look like Arch Linux."

    run_as_root pacman -Sy --needed python python-pip python-virtualenv

    create_venv_and_install_python_deps "python"
}

install_ubuntu() {
    echo
    echo "Installing dependencies for Ubuntu/Debian..."

    command_exists apt || die "apt not found. This does not look like Ubuntu/Debian."

    run_as_root apt update
    run_as_root apt install -y python3 python3-pip python3-venv

    create_venv_and_install_python_deps "python3"
}

install_menu() {
    print_header

    echo "Choose platform:"
    echo "1) Termux"
    echo "2) Arch Linux"
    echo "3) Ubuntu/Debian"
    echo "0) Back"
    echo

    read -r -p "Select option: " choice

    case "$choice" in
        1)
            install_termux
            ;;
        2)
            install_arch
            ;;
        3)
            install_ubuntu
            ;;
        0)
            return
            ;;
        *)
            echo "Unknown option."
            ;;
    esac

    pause
}

ensure_venv_exists() {
    if [[ ! -x "$PYTHON_BIN" ]]; then
        die "Virtual environment not found. Run Install first."
    fi
}

choose_role() {
    echo "Choose role:" >&2
    echo "1) Sender" >&2
    echo "2) Receiver" >&2
    echo "0) Back" >&2
    echo >&2

    read -r -p "Select option: " role

    case "$role" in
        1)
            echo "sender"
            ;;
        2)
            echo "receiver"
            ;;
        0)
            echo "back"
            ;;
        *)
            echo "invalid"
            ;;
    esac
}

choose_connection_args() {
    echo
    echo "Choose Meshtastic connection:"
    echo "1) Wi-Fi / TCP host"
    echo "2) USB serial port"
    echo "3) Auto/default serial"
    echo

    read -r -p "Select option: " connection

    case "$connection" in
        1)
            local host
            host="$(ask_required "Enter Meshtastic node IP or hostname")"
            CONNECTION_ARGS=(--host "$host")
            ;;
        2)
            local port
            port="$(ask_required "Enter serial port, for example /dev/ttyUSB0 or /dev/ttyACM0")"
            CONNECTION_ARGS=(--port "$port")
            ;;
        3)
            CONNECTION_ARGS=()
            ;;
        *)
            echo "Unknown option. Using auto/default serial."
            CONNECTION_ARGS=()
            ;;
    esac
}

run_sender() {
    print_header
    echo "Sender setup"
    echo

    choose_connection_args

    local run_id
    local interval

    run_id="$(ask "Run ID" "test01")"
    interval="$(ask "Send interval in seconds" "60")"

    echo
    echo "Starting sender..."
    echo "Script: $SENDER_SCRIPT"
    echo "Run ID: $run_id"
    echo "Interval: $interval sec"
    echo

    "$PYTHON_BIN" "$SENDER_SCRIPT" \
        "${CONNECTION_ARGS[@]}" \
        --run-id "$run_id" \
        --interval "$interval"
}

run_receiver() {
    print_header
    echo "Receiver setup"
    echo

    choose_connection_args

    local out
    local sender_lat
    local sender_lon
    local gps_args=()

    out="$(ask "Output CSV path" "$ROOT_DIR/test01.csv")"
    sender_lat="$(ask_required "Sender latitude")"
    sender_lon="$(ask_required "Sender longitude")"

    if ask_yes_no "Use Termux GPS via termux-location? y/n" "y"; then
        gps_args=(--use-termux-gps)
    fi

    echo
    echo "Starting receiver..."
    echo "Script: $RECEIVER_SCRIPT"
    echo "Output: $out"
    echo "Sender coordinates: $sender_lat, $sender_lon"
    echo

    "$PYTHON_BIN" "$RECEIVER_SCRIPT" \
        "${CONNECTION_ARGS[@]}" \
        --out "$out" \
        --sender-lat "$sender_lat" \
        --sender-lon "$sender_lon" \
        "${gps_args[@]}"
}

run_menu() {
    ensure_project_structure
    ensure_venv_exists

    print_header

    local role
    role="$(choose_role)"

    case "$role" in
        sender)
            run_sender
            ;;
        receiver)
            run_receiver
            ;;
        back)
            return
            ;;
        *)
            echo "Unknown option."
            pause
            ;;
    esac
}

main_menu() {
    while true; do
        print_header

        echo "Main menu:"
        echo "1) Install"
        echo "2) Run"
        echo "0) Exit"
        echo

        read -r -p "Select option: " choice

        case "$choice" in
            1)
                install_menu
                ;;
            2)
                run_menu
                ;;
            0)
                echo "Bye."
                exit 0
                ;;
            *)
                echo "Unknown option."
                pause
                ;;
        esac
    done
}

main_menu
