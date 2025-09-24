#!/bin/bash

# Author: Rilix
# Description: Installation script for setting up the Oculus log capturing
# Version: BR v.01

###############################################################################
# Colors for logging
###############################################################################
YELLOW='\033[1;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

set -o nounset
set -o errexit
trap 'printf "${RED}Aborting due to errexit on line $LINENO. Exit code: $?${NC}\n" >&2' ERR
set -o errtrace
set -o pipefail

###############################################################################
# Log functions
###############################################################################

__LOG_COUNTER=0

_log() {
  __LOG_COUNTER=$((__LOG_COUNTER+1))
  printf "${GREEN}#  %s " "${__LOG_COUNTER}"
  "${@}"
  printf "${NC}\n"
}

log() {
  _log echo "${@}"
}

_die() {
  printf "❌"
  "${@}" 1>&2
  exit 1
}

die() {
  _die echo "${@}"
}

###############################################################################
# Installation steps
###############################################################################

# Step 0: Install curl if not available
log "Checking if curl is installed..."
if ! command -v curl &> /dev/null; then
  log "curl not found, installing..."
  if command -v apt-get &> /dev/null; then
    sudo apt-get update && sudo apt-get install -y curl
  elif command -v yum &> /dev/null; then
    sudo yum install -y curl
  elif command -v dnf &> /dev/null; then
    sudo dnf install -y curl
  elif command -v pacman &> /dev/null; then
    sudo pacman -S --noconfirm curl
  else
    die "Package manager not found. Please install curl manually."
  fi
  log "curl installation completed."
else
  log "curl is already installed."
fi

# Step 1: Remove old cron jobs related to Rilix_coaster_stats.sh
log "Removing old cron jobs related to Rilix_coaster_stats.sh..."
# Check if the crontab has existing entries
if sudo crontab -l 2>/dev/null | grep -q '/opt/RilixScripts/Rilix_coaster_stats.sh'; then
  sudo crontab -l | grep -v '/opt/RilixScripts/Rilix_coaster_stats.sh' | sudo crontab -
  log "Old cron jobs removed."
else
  log "No existing cron jobs found for Rilix_coaster_stats.sh."
fi

# Step 2: Define the installation directory
installDir="/opt/RilixScripts"
scriptPath="$installDir/Rilix_coaster_stats.sh"

# Create the installation directory if it doesn't exist
log "Creating installation directory at $installDir..."
if [ ! -d "$installDir" ]; then
  sudo mkdir -p "$installDir"
  log "Installation directory created."
else
  log "Installation directory already exists."
fi

# Step 3: Remove old scripts if they exist
if [ -f "$installDir/Rilix_coaster_stats.sh" ]; then
  sudo rm "$installDir/Rilix_coaster_stats.sh"
  log "Rilix_coaster_stats.sh removed."
else
  log "Rilix_coaster_stats.sh does not exist."
fi

# Step 4: Write the log capturing script to the installation directory
log "Writing the log capturing script to $scriptPath..."
sudo tee "$scriptPath" > /dev/null << 'EOF'
#!/bin/bash

# Version stats: BR v.01

# Ensure PATH is set correctly for cron
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Define the log directory base
logBaseDir="/home/rilix/Rilix_coaster_stats_br"

# Define a temporary file for storing captured lines
tempFile="/tmp/oculus_log_capture.tmp"

# Define some variables
sudoPactl="sudo -u rilix XDG_RUNTIME_DIR=/run/user/$(id -u rilix) pactl"
sudoArduinoCli="sudo -u rilix XDG_RUNTIME_DIR=/run/user/$(id -u rilix) /opt/arduino-cli//arduino-cli"

# Function to capture PC CPU data
capture_pc_data() {
  # Capture CPU temperature with error handling
  pcCpuTemp=$(sensors 2>/dev/null | grep 'Package id 0' | awk '{print $4}' | sed 's/+//;s/°C//' | head -1)
  pcCpuTemp=${pcCpuTemp:-"N/A"}
  
  # Capture CPU frequency with error handling
  pcCpuFreq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
  if [[ $pcCpuFreq =~ ^[0-9]+$ ]]; then
    pcCpuFreq=$(echo "scale=1; $pcCpuFreq / 1000" | bc 2>/dev/null)
    pcCpuFreq="${pcCpuFreq}MHz"
  else
    pcCpuFreq="N/A"
  fi

  # Capture CPU load percentage with error handling
  pcCpuLoad=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2 + $4}' | head -1)
  if [[ "$pcCpuLoad" =~ ^[0-9.]+$ ]]; then
    pcCpuLoad=$(echo "${pcCpuLoad}%" | sed 's/,/./g')
  else
    pcCpuLoad="N/A"
  fi
  
  # Get license information from API endpoint
  get_license_info
}

# Function to count lines already written for a specific serial at the current date and time
count_lines_written_for_serial() {
  local logFile="$1"
  local serial="$2"
  local currentDate="$3"
  local currentTime="$4"

  # Count lines for the current serial, date, and time
  awk -F',' -v serial="$serial" -v date="$currentDate" -v time="$currentTime" \
  '$1 == date && $2 == time && $3 == serial { count++ } END { print count+0 }' "$logFile"
}

# Check the status of the Rilix Board
rilixBoardStatus=$(lsusb | grep -iq 'Arduino' && echo "board found" || echo "BOARD NOT FOUND")

# Function to calculate battery health using Charge Counter for Oculus Quest 2
# The nominal battery levels are 3640000, increased for better understanding of battery health levels.
calculate_battery_health() {
    local chargeCounter="$1"
    local batteryStatus="$2"
    local nominalChargeCounter=4000000
        # redundant line to state battery level in % before the 'if' check
    local batteryStatus=$(echo "$adbInfo" | sed -n '1p')

    if (( batteryStatus > 95 )); then
        batteryHealth=$(echo "scale=2; ($chargeCounter * 100) / $nominalChargeCounter" | bc)
        echo "$batteryHealth%"
    fi
}

# Function for Fast Charging Check. (>= 0.6 AMPÈRE, or 600000 micro ampères)
check_fast_charging() {

    # redundant line to state the current(micro ampère) before the 'if' check
    local maxChargingCurrent=$(echo "$adbInfo" | sed -n '7p')

    if (( maxChargingCurrent >= 600000 )); then
        fastChargingState="fast"
    else
        fastChargingState="SLOW CHARGING"
    fi
}

# Function to fetch license information from API endpoint
get_license_info() {
  # Set default values
  licenseKey="N/A"
  licenseLabel="N/A"
  licenseActivationId="N/A"
  licenseSerialHardware="N/A"
  licenseSerialMotherboard="N/A"
  licenseSerialDisk="N/A"
  
  # Try to fetch from API
  local license_response
  license_response=$(curl -s --max-time 5 --retry 1 "http://localhost/api/license" 2>/dev/null)
  
  # If we got a valid response, extract the values
  if [ $? -eq 0 ] && [ -n "$license_response" ]; then
    # Extract each field using grep and cut - this method is resistant to variations in JSON formatting
    licenseKey=$(echo "$license_response" | grep -o '"key"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "N/A")
    licenseLabel=$(echo "$license_response" | grep -o '"label"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "N/A")
    licenseActivationId=$(echo "$license_response" | grep -o '"activationId"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "N/A")
    licenseSerialHardware=$(echo "$license_response" | grep -o '"serialHardware"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "N/A")
    licenseSerialMotherboard=$(echo "$license_response" | grep -o '"serialMotherboard"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "N/A")
    licenseSerialDisk=$(echo "$license_response" | grep -o '"serialDisk"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "N/A")
    
    # Handle empty values
    [ -z "$licenseKey" ] && licenseKey="N/A"
    [ -z "$licenseLabel" ] && licenseLabel="N/A"
    [ -z "$licenseActivationId" ] && licenseActivationId="N/A"
    [ -z "$licenseSerialHardware" ] && licenseSerialHardware="N/A"
    [ -z "$licenseSerialMotherboard" ] && licenseSerialMotherboard="N/A"
    [ -z "$licenseSerialDisk" ] && licenseSerialDisk="N/A"
  fi
}

# Function to check state of device (device, unauthorized, offline, recovery, etc)
get_device_state(){
  local isDeviceUnauthorized=$(adb devices | grep -iq "unauthorized" && echo "yes" || echo "no")
  local howManyDevices=$(( $(adb devices | wc -l) - 2 ))
  deviceState=$(adb -s "$SERIAL" get-state)
  local error1=$(adb devices | grep -qiE 'error|not found|failed|recover' && echo "yes" || echo "no")
  local error2=$(adb devices | grep -qi offline && echo "yes" || echo "no")

  # The command adb devices can return a multitude of messages, which would break the script. To make this resilient, we'll do some checks for the possible error messages with these variables
  # If any of the errors are true, stop prematurely and print error

  if [[ "$howManyDevices" -lt 0 ]]; then
    deviceState="CRITICAL ERROR" 
  elif [[ "$error1" == "yes" ]]; then
    deviceState="STRANGE STATE"
  elif [[ "$error2" == "yes" ]]; then
    deviceState="OFFLINE ERROR"
  elif [[ "$isDeviceUnauthorized" == "yes" ]]; then
    deviceState="UNAUTHORIZED"
  # Redundant line to make the script more readable
  elif [[ "$(adb -s "$SERIAL" get-state | xargs)" == "device" ]]; then
    deviceState="device"
  # (No headsets connected)
  elif [[ $howManyDevices -eq 0 ]]; then
            if adb devices | grep -iq "list of devices attached"; then
              deviceState="NOT FOUND"
            fi
  else
    deviceState="UNKNOWN ERROR"
  fi
}

# Function to extract database_monitoring data. It resists to variable made out solely of spaces ("       ") and also to being empty (""), they have to be at least 4 characters long, except country (at least 2).
get_database_monitoring_entries(){

  # Database name
  databaseMonitoringTeamviewerName=$(grep -Po '(?<=TEAMVIEWER_CLIENTE=").*(?=")' /opt/RilixScripts/database_monitoring.sh 2>/dev/null)
  if [[ -z $(echo "$databaseMonitoringTeamviewerName" | xargs) ]]; then
    databaseMonitoringTeamviewerName="ENTRY NOT FOUND"
  elif [[ ! "$databaseMonitoringTeamviewerName" =~ [[:alnum:]] ]]; then
    databaseMonitoringTeamviewerName="STRANGE ENTRY"
  elif [[ ${#databaseMonitoringTeamviewerName} -le 4 ]]; then
    databaseMonitoringTeamviewerName="SHORT ENTRY"
  fi

  databaseMonitoringKey=$(grep -Po '(?<=KEY=").*(?=")' /opt/RilixScripts/database_monitoring.sh 2>/dev/null)
  if [[ -z $(echo "$databaseMonitoringKey" | xargs) ]]; then
    databaseMonitoringKey="ENTRY NOT FOUND"
  elif [[ ! "$databaseMonitoringKey" =~ [[:alnum:]] ]]; then
    databaseMonitoringKey="STRANGE ENTRY"
  elif [[ ${#databaseMonitoringKey} -le 4 ]]; then
    databaseMonitoringKey="SHORT ENTRY"
  fi

  databaseMonitoringCountry=$(grep -Po '(?<=COUNTRIE=").*(?=")' /opt/RilixScripts/database_monitoring.sh 2>/dev/null)
  if [[ -z $(echo "$databaseMonitoringCountry" | xargs) ]]; then
    databaseMonitoringCountry="ENTRY NOT FOUND"
  elif [[ ! "$databaseMonitoringCountry" =~ [[:alnum:]] ]]; then
    databaseMonitoringCountry="STRANGE ENTRY"
  elif [[ ${#databaseMonitoringCountry} -le 1 ]]; then
    databaseMonitoringCountry="SHORT ENTRY"
  fi
}

# Function to check if game is closed
get_is_game_closed(){
  # Check if RCLauncher or BCLauncher are running
  ps aux | grep -v grep | grep -E -q "RCLauncher|BCLauncher"
  local isGameClosedHash=$?
  # Also declaring isGameClosed which will be used later, it's a global variable.

  # 0: confirmation. 1: negation. 2: grep error.
  if [[ $isGameClosedHash -eq 0 ]]; then
    isGameClosed="game running"
  elif [[ $isGameClosedHash -eq 1 ]]; then
    isGameClosed="GAME CLOSED"
  elif [[ $isGameClosedHash -eq 2 ]]; then
    isGameClosed="GREP ERROR"
  else 
    isGameClosed="UNKNOWN ERROR"
  fi
}

# This function depends on the state of the next (isTvDefaultOutput) one, so we're running this one FIRST, but it appears AFTER on the .csv file, for convenience when reading. 
get_default_output_volume(){
  # The usual $? check doesn't work because pactl has to run on the user, not sudo, there's a variable defined in the start that runs pactl as sudo
  defaultOutput=$($sudoPactl info | grep -oP '(?<=Default Sink: ).*')
  defaultOutputVolume="$($sudoPactl list sinks | grep -i -A 11 "$defaultOutput" | grep -oP '(?<=front-right).*' | grep -ioP '\d+(?=%)')"

  local muteStatus=$($sudoPactl list sinks | awk -v sink="$defaultOutput" '
    $0 ~ "Name: *"sink { inSink=1 }
    inSink && /Mute:/ { print $2; exit }
  ')

  if [[ "$muteStatus" == "yes" ]]; then
    defaultOutputVolume="${defaultOutputVolume}%-MUTED"
    return 0
  elif [[ $defaultOutputVolume -eq 0 ]]; then
    # Show MUTED if volume is zeroed out
    defaultOutputVolume="${defaultOutputVolume}%-MUTED"
    return 0
  elif [[ $(sudoPactl info | grep -i muted | grep -iq y && echo "YES") == "YES" ]]; then
    # Show MUTED if the mute button is toggled on
    defaultOutputVolume="${defaultOutputVolume}%-MUTED"
    return 0
  elif [[ $defaultOutputVolume -le 79 ]]; then
    # Show LOW VOL. if volume is less than 80
    defaultOutputVolume="${defaultOutputVolume}%-LOW VOL."
    return 0
  elif [[ $defaultOutputVolume -ge 80 ]]; then
    defaultOutputVolume="${defaultOutputVolume}%"
    return 0
  fi
}

# Function to check if the AUDIO OUTPUT is the TV OR NULL (error if yes)
get_is_tv_default_output(){
  if $sudoPactl info | grep -iq hdmi; then
    isTvDefaultOutput="TV IS DEFAULT"
  elif $sudoPactl info | grep -iqE 'dummy|null|discard|invalid|none'; then
    isTvDefaultOutput="WRONG OUTPUT"
  fi

  if [[ "$isTvDefaultOutput" == "TV IS DEFAULT" || "$isTvDefaultOutput" == "WRONG OUTPUT" ]]; then 
  defaultOutputVolume="$($sudoPactl list sinks | grep -i -A 7 "$defaultOutput" | grep -oP '(?<=front-right).*' | grep -ioP '\d+(?=%)')%-WRONG OUTPUT"
  fi
}

# Function to check if the Arduino programmer is set as "mkii"
get_is_arduino_programmer_mkii(){
    grep -iq mkii /home/rilix/.arduino15/preferences.txt
    local isArduinoProgrammerMkiiHash=$?
    # Also declaring arduinoProgrammer which will be used later, it's a global variable.

    if [[ $isArduinoProgrammerMkiiHash -eq 0 ]]; then
        arduinoProgrammer="mkii is programmer"
    elif [[ $isArduinoProgrammerMkiiHash -eq 1 ]]; then
        arduinoProgrammer="WRONG PROGRAMMER"
    elif [[ $isArduinoProgrammerMkiiHash -eq 2 ]]; then
        arduinoProgrammer="GREP ERROR"
    else
        arduinoProgrammer="UNKNOWN ERROR"
    fi
}

# Function to check if Arduino is on the right port
get_is_arduino_correct_port(){

    # "grep found" is for "No boards found." Running this in a simulated environment for user rilix
    $sudoArduinoCli board list | grep -i found
    local isArduinoNotConnectedHash=$?
    
    grep -iq acm0 /home/rilix/.arduino15/preferences.txt
    local isArduinoCorrectPortHash=$?

    if [[ $isArduinoNotConnectedHash -eq 0 ]]; then
      isArduinoCorrectPort="BOARD NOT FOUND"
    elif [[ $isArduinoNotConnectedHash -eq 1 && $isArduinoCorrectPortHash -eq 0 ]]; then
      isArduinoCorrectPort="correct port acm0"
    elif [[ $isArduinoNotConnectedHash -eq 1 && $isArduinoCorrectPortHash -eq 1 ]]; then
      isArduinoCorrectPort="WRONG BOARD PORT"
    else
      isArduinoCorrectPort="UNKNOWN ERROR"
    fi
}

# Function to check if Arduino is configured as the correct board type (Micro)
get_is_arduino_board_micro(){
    grep -iq micro /home/rilix/.arduino15/preferences.txt
    local isArduinoBoardMicroHash=$?

    if [[ $isArduinoBoardMicroHash -eq 0 ]]; then
        isArduinoBoardMicro="type micro"
    elif [[ $isArduinoBoardMicroHash -eq 1 ]]; then
        isArduinoBoardMicro="WRONG BOARD TYPE"
    elif [[ $isArduinoBoardMicroHash -eq 2 ]]; then
        isArduinoBoardMicro="GREP ERROR"
    else
        isArduinoBoardMicro="UNKNOWN ERROR"
    fi
}

# Function to check if TeamViewer is assigned to the Rilix account
get_is_teamviewer_assigned(){
    sudo cat /opt/teamviewer/config/global.conf | grep -iq rilix
    local isTeamViewerAssignedHash=$?
    # Also declaring isTeamViewerAssigned which will be used later, it's a global variable.

    if [[ $isTeamViewerAssignedHash -eq 0 ]]; then
        isTeamViewerAssigned="teamviewer ok"
    elif [[ $isTeamViewerAssignedHash -eq 1 ]]; then
        isTeamViewerAssigned="ATTENTION-TEAMVIEWER NOT ASSIGNED"
    elif [[ $isTeamViewerAssignedHash -eq 2 ]]; then
        isTeamViewerAssigned="GREP ERROR"
    else
        isTeamViewerAssigned="UNKOWN ERROR"
    fi
}

# Function to check if Anydesk has the wrong/duplicated ID setup (rilix@ad, i.e. 715555530)
get_is_anydesk_id_duplicated(){
    isAnydeskIdDuplicatedHash=$(anydesk --get-id)
    
  if [[ $isAnydeskIdDuplicatedHash == 715555530 ]]; then
    isAnydeskIdDuplicated="DUPLICATED-RILIX@AD"
  else
    isAnydeskIdDuplicated="anydesk id ok"
  fi
}

# Function to test Heroku connectivity
test_heroku_connectivity() {
  local heroku_url="https://rilix-stats-app-br-e7381e9071b5.herokuapp.com/"
  
  echo "$(date): Testing Heroku connectivity..." >> /tmp/heroku_debug.log
  
  # Test basic connectivity
  local response=$(curl -w "HTTPCODE:%{http_code}" --max-time 10 --retry 1 -s "$heroku_url" 2>&1)
  local exit_code=$?
  local http_code=$(echo "$response" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)
  
  if [ $exit_code -eq 0 ] && [[ "$http_code" =~ ^[2-5][0-9][0-9]$ ]]; then
    echo "$(date): Heroku connectivity OK (HTTP: $http_code)" >> /tmp/heroku_debug.log
    return 0
  else
    echo "$(date): Heroku connectivity FAILED (Exit: $exit_code, HTTP: $http_code)" >> /tmp/heroku_debug.log
    return 1
  fi
}

# Function to sanitize strings for JSON
sanitize_json_string() {
  local input="$1"
  # Remove control characters, escape quotes and backslashes
  echo "$input" | sed 's/[\x00-\x1F\x7F]//g' | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | head -c 200
}

# Function to create valid JSON data
create_json_payload() {
  local date="$1" time="$2" num_devices="$3" serial="$4" version_oculus="$5"
  local battery_percent="$6" fast_charging="$7" screen_state="$8" device_state="$9"
  shift 9
  local game_closed="$1" rilix_board="$2" arduino_programmer="$3" arduino_port="$4"
  local arduino_type="$5" default_output="$6" volume="$7" teamviewer_assigned="$8"
  local anydesk_id_state="$9"
  shift 9
  local database_teamviewer_id="$1" database_key="$2" database_country="$3"
  local max_charging_current="$4" max_charging_voltage="$5" charge_counter="$6"
  local battery_health="$7" pid_quest="$8" cpu_quest="$9"
  shift 9
  local mem_quest="$1" args_quest="$2" pc_cpu_temp="$3" pc_cpu_frequency="$4"
  local pc_cpu_load="$5" quest_cpu_temp1="$6" quest_cpu_temp2="$7"
  local quest_md1_temp="$8" quest_io_chip_temp="$9"
  shift 9
  local license_key="$1" license_label="$2" license_activation_id="$3"
  local license_serial_motherboard="$4" license_serial_disk="$5" license_serial_hardware="$6"
  
  # Sanitize all fields
  date=$(sanitize_json_string "$date")
  time=$(sanitize_json_string "$time")
  num_devices=$(sanitize_json_string "$num_devices")
  serial=$(sanitize_json_string "$serial")
  version_oculus=$(sanitize_json_string "$version_oculus")
  battery_percent=$(sanitize_json_string "$battery_percent")
  fast_charging=$(sanitize_json_string "$fast_charging")
  screen_state=$(sanitize_json_string "$screen_state")
  device_state=$(sanitize_json_string "$device_state")
  game_closed=$(sanitize_json_string "$game_closed")
  rilix_board=$(sanitize_json_string "$rilix_board")
  arduino_programmer=$(sanitize_json_string "$arduino_programmer")
  arduino_port=$(sanitize_json_string "$arduino_port")
  arduino_type=$(sanitize_json_string "$arduino_type")
  default_output=$(sanitize_json_string "$default_output")
  volume=$(sanitize_json_string "$volume")
  teamviewer_assigned=$(sanitize_json_string "$teamviewer_assigned")
  anydesk_id_state=$(sanitize_json_string "$anydesk_id_state")
  database_teamviewer_id=$(sanitize_json_string "$database_teamviewer_id")
  database_key=$(sanitize_json_string "$database_key")
  database_country=$(sanitize_json_string "$database_country")
  max_charging_current=$(sanitize_json_string "$max_charging_current")
  max_charging_voltage=$(sanitize_json_string "$max_charging_voltage")
  charge_counter=$(sanitize_json_string "$charge_counter")
  battery_health=$(sanitize_json_string "$battery_health")
  pid_quest=$(sanitize_json_string "$pid_quest")
  cpu_quest=$(sanitize_json_string "$cpu_quest")
  mem_quest=$(sanitize_json_string "$mem_quest")
  args_quest=$(sanitize_json_string "$args_quest")
  pc_cpu_temp=$(sanitize_json_string "$pc_cpu_temp")
  pc_cpu_frequency=$(sanitize_json_string "$pc_cpu_frequency")
  pc_cpu_load=$(sanitize_json_string "$pc_cpu_load")
  quest_cpu_temp1=$(sanitize_json_string "$quest_cpu_temp1")
  quest_cpu_temp2=$(sanitize_json_string "$quest_cpu_temp2")
  quest_md1_temp=$(sanitize_json_string "$quest_md1_temp")
  quest_io_chip_temp=$(sanitize_json_string "$quest_io_chip_temp")
  license_key=$(sanitize_json_string "$license_key")
  license_label=$(sanitize_json_string "$license_label")
  license_activation_id=$(sanitize_json_string "$license_activation_id")
  license_serial_motherboard=$(sanitize_json_string "$license_serial_motherboard")
  license_serial_disk=$(sanitize_json_string "$license_serial_disk")
  license_serial_hardware=$(sanitize_json_string "$license_serial_hardware")
  
  # Create properly formatted JSON
  printf '{
  "date": "%s",
  "time": "%s",
  "num_devices": "%s",
  "serial": "%s",
  "version_oculus": "%s",
  "battery_percent": "%s",
  "fast_charging": "%s",
  "screen_state": "%s",
  "device_state": "%s",
  "game_closed": "%s",
  "rilix_board": "%s",
  "arduino_programmer": "%s",
  "arduino_port": "%s",
  "arduino_type": "%s",
  "default_output": "%s",
  "volume": "%s",
  "teamviewer_assigned": "%s",
  "anydesk_id_state": "%s",
  "database_teamviewer_id": "%s",
  "database_key": "%s",
  "database_country": "%s",
  "max_charging_current": "%s",
  "max_charging_voltage": "%s",
  "charge_counter": "%s",
  "battery_health": "%s",
  "pid_quest": "%s",
  "cpu_quest": "%s",
  "mem_quest": "%s",
  "args_quest": "%s",
  "pc_cpu_temp": "%s",
  "pc_cpu_frequency": "%s",
  "pc_cpu_load": "%s",
  "quest_cpu_temp1": "%s",
  "quest_cpu_temp2": "%s",
  "quest_md1_temp": "%s",
  "quest_io_chip_temp": "%s",
  "license_key": "%s",
  "license_label": "%s",
  "license_activation_id": "%s",
  "license_serial_motherboard": "%s",
  "license_serial_disk": "%s",
  "license_serial_hardware": "%s"
}' "$date" "$time" "$num_devices" "$serial" "$version_oculus" "$battery_percent" "$fast_charging" "$screen_state" "$device_state" "$game_closed" "$rilix_board" "$arduino_programmer" "$arduino_port" "$arduino_type" "$default_output" "$volume" "$teamviewer_assigned" "$anydesk_id_state" "$database_teamviewer_id" "$database_key" "$database_country" "$max_charging_current" "$max_charging_voltage" "$charge_counter" "$battery_health" "$pid_quest" "$cpu_quest" "$mem_quest" "$args_quest" "$pc_cpu_temp" "$pc_cpu_frequency" "$pc_cpu_load" "$quest_cpu_temp1" "$quest_cpu_temp2" "$quest_md1_temp" "$quest_io_chip_temp" "$license_key" "$license_label" "$license_activation_id" "$license_serial_motherboard" "$license_serial_disk" "$license_serial_hardware"
}

fix_csv_inner_quoting(){
  echo "$1" | sed 's/"/""/g'  
}

# Function to send data to Heroku application
send_data_to_heroku() {
  local data="$1"
  local heroku_url="https://rilix-stats-app-br-e7381e9071b5.herokuapp.com/upload"
  local api_key="JtWgFdQ7G6szQFhGkrYe3oFbfy5EcLBR"
  local temp_json="/tmp/heroku_data_$(date +%s)_$$.json"
  
  # Debug: Log the attempt
  echo "$(date): Attempting to send data to Heroku" >> /tmp/heroku_debug.log
  echo "Data preview: ${data:0:200}..." >> /tmp/heroku_debug.log
  
  # Validate JSON data before sending
  if [ -z "$data" ] || [ "$data" = "{}" ] || [ "$data" = "null" ]; then
    echo "ERROR: Invalid or empty JSON data, skipping Heroku send" >> /tmp/heroku_debug.log
    return 1
  fi
  
  # Sanitize JSON data to remove potential problematic characters
  local sanitized_data=$(echo "$data" | sed 's/[\x00-\x1F\x7F]//g' | sed 's/\\\\/\\/g')
  
  # Write JSON data to temporary file to avoid shell escaping issues
  echo "$sanitized_data" > "$temp_json"
  
  # Validate JSON file exists and has content
  if [ ! -s "$temp_json" ]; then
    echo "ERROR: Temporary JSON file is empty, skipping Heroku send" >> /tmp/heroku_debug.log
    rm -f "$temp_json"
    return 1
  fi
  
  # Test JSON validity by trying to read it back
  local json_test=$(cat "$temp_json" 2>/dev/null)
  if [ -z "$json_test" ]; then
    echo "ERROR: JSON file validation failed" >> /tmp/heroku_debug.log
    rm -f "$temp_json"
    return 1
  fi
  
  # Send data via curl with comprehensive headers (mimicking Postman)
  local response=$(curl -w "HTTPCODE:%{http_code}|TIME:%{time_total}" \
    --max-time 30 \
    --retry 2 \
    --retry-delay 1 \
    -X POST "$heroku_url" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $api_key" \
    -H "User-Agent: RilixStats/1.0" \
    -H "Accept: application/json" \
    --data-binary "@$temp_json" 2>&1)
  
  local exit_code=$?
  
  # Extract metrics from response
  local http_code=$(echo "$response" | grep -o "HTTPCODE:[0-9]*" | cut -d: -f2)
  local time_total=$(echo "$response" | grep -o "TIME:[0-9.]*" | cut -d: -f2)
  
  # Remove metrics from response body
  local response_body=$(echo "$response" | sed 's/HTTPCODE:[0-9]*|TIME:[0-9.]*$//')
  
  # Cleanup temp file
  rm -f "$temp_json"
  
  # Log comprehensive result
  echo "$(date): HTTP Code: $http_code, Exit Code: $exit_code, Time: ${time_total}s" >> /tmp/heroku_debug.log
  echo "Response Body: $response_body" >> /tmp/heroku_debug.log
  
  # Detailed error handling
  if [ $exit_code -ne 0 ]; then
    echo "ERROR: Curl failed with exit code: $exit_code" >> /tmp/heroku_debug.log
    echo "Full curl response: $response" >> /tmp/heroku_debug.log
    return 1
  elif [ -z "$http_code" ]; then
    echo "ERROR: No HTTP code received from server" >> /tmp/heroku_debug.log
    return 1
  elif [[ ! "$http_code" =~ ^(200|201)$ ]]; then
    echo "ERROR: HTTP $http_code - Server rejected request" >> /tmp/heroku_debug.log
    echo "Response: $response_body" >> /tmp/heroku_debug.log
    return 1
  else
    echo "SUCCESS: Data sent to Heroku (HTTP: $http_code, Time: ${time_total}s)" >> /tmp/heroku_debug.log
    return 0
  fi
}

# Function to create a placeholder entry when no devices are connected
create_placeholder_entry(){
  local currentDate=$(date +"%Y-%m-%d")
  local currentTime=$(date +"%H-%M")
  local currentMonth=$(date +"%Y-%m")

  # Define log file and directory paths
  local logDir="$logBaseDir/$currentMonth"
  local logFile="$logDir/${currentDate}.csv"

  mkdir -p "$logDir"

  # Add header if log file doesn't exist, no fix for special characters needed, as the header will never have those.
  if [ ! -f "$logFile" ]; then
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "Date" \
      "Time" \
      "NºDevices" \
      "Serial" \
      "Version Oculus" \
      "Battery %" \
      "Fast Charging?" \
      "Screen State" \
      "Device State" \
      "Game closed?" \
      "Rilix Board" \
      "Arduino Programmer" \
      "Arduino Port" \
      "Arduino Type" \
      "Default Output" \
      "Volume" \
      "TeamViewer Assigned?" \
      "AnydeskID state" \
      "Database TeamViewer ID" \
      "Database KEY" \
      "Database Country" \
      "Max Charging Current" \
      "Max Charging Voltage" \
      "Charge Counter" \
      "Battery Health %" \
      "PID quest" \
      "%CPU quest" \
      "%MEM quest" \
      "ARGS quest" \
      "PC CPU Temp" \
      "PC CPU Frequency" \
      "PC CPU Load" \
      "quest CPU Temp 1" \
      "quest CPU Temp 2" \
      "quest MD1 Temp" \
      "quest IO Chip Temp" > "$logFile"
  fi

  # Capture PC data
  capture_pc_data

  # Check multiple functions
  get_database_monitoring_entries
  get_device_state
  get_is_game_closed
  get_default_output_volume
  get_is_tv_default_output
  get_is_arduino_programmer_mkii
  get_is_arduino_board_micro
  get_is_teamviewer_assigned
  get_is_arduino_correct_port
  get_is_anydesk_id_duplicated
  get_license_info

  # Write placeholder log entry, this function prevents quotes from breaking the function.
  printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
   "$currentDate" \
    "$currentTime" \
    "0" \
    "N/A" \
    "N/A" \
    "N/A" \
    "N/A" \
    "N/A" \
    "$deviceState" \
    "$isGameClosed" \
    "$rilixBoardStatus" \
    "$arduinoProgrammer" \
    "$isArduinoCorrectPort" \
    "$isArduinoBoardMicro" \
    "$isTvDefaultOutput" \
    "$(fix_csv_inner_quoting "$defaultOutputVolume")" \
    "$isTeamViewerAssigned" \
    "$isAnydeskIdDuplicated" \
    "$(fix_csv_inner_quoting "$databaseMonitoringTeamviewerName")" \
    "$(fix_csv_inner_quoting "$databaseMonitoringKey")" \
    "$(fix_csv_inner_quoting "$databaseMonitoringCountry")" \
    "N/A" \
    "N/A" \
    "N/A" \
    "N/A" \
    "N/A" \
    "N/A" \
    "N/A" \
    "N/A" \
    "$pcCpuTemp" \
    "$pcCpuFreq" \
    "$pcCpuLoad" \
    "N/A" \
    "N/A" \
    "N/A" \
    "N/A" \
    "$(fix_csv_inner_quoting "$licenseKey")" \
    "$(fix_csv_inner_quoting "$licenseLabel")" \
    "$(fix_csv_inner_quoting "$licenseActivationId")" \
    "$(fix_csv_inner_quoting "$licenseSerialMotherboard")" \
    "$(fix_csv_inner_quoting "$licenseSerialDisk")" \
    "$(fix_csv_inner_quoting "$licenseSerialHardware")" >> "$logFile"
  
  # Prepare JSON data to send to Heroku using the dedicated function
  local json_data=$(create_json_payload \
    "$currentDate" "$currentTime" "0" "N/A" "N/A" "N/A" "N/A" "N/A" \
    "$deviceState" "$isGameClosed" "$rilixBoardStatus" "$arduinoProgrammer" \
    "$isArduinoCorrectPort" "$isArduinoBoardMicro" "$isTvDefaultOutput" "$defaultOutputVolume" \
    "$isTeamViewerAssigned" "$isAnydeskIdDuplicated" "$databaseMonitoringTeamviewerName" \
    "$databaseMonitoringKey" "$databaseMonitoringCountry" "N/A" "N/A" "N/A" "N/A" \
    "N/A" "N/A" "N/A" "N/A" "$pcCpuTemp" "$pcCpuFreq" "$pcCpuLoad" \
    "N/A" "N/A" "N/A" "N/A" "$licenseKey" "$licenseLabel" "$licenseActivationId" \
    "$licenseSerialMotherboard" "$licenseSerialDisk" "$licenseSerialHardware")
  
  # ALWAYS send data to Heroku
  send_data_to_heroku "$json_data"
  
  echo "Captured placeholder log entry to $logFile and sent data to Heroku"
}

# Function to capture logs for a given device
capture_logs() {
  local SERIAL="$2"
  local currentDate=$(date +"%Y-%m-%d")
  local currentTime=$(date +"%H-%M")
  local currentMonth=$(date +"%Y-%m")
  
  # Initialize license variables
  licenseKey="N/A"
  licenseLabel="N/A"
  licenseActivationId="N/A"
  licenseSerialHardware="N/A"
  licenseSerialMotherboard="N/A"
  licenseSerialDisk="N/A"

  # Define log directory and file path
  local logDir="$logBaseDir/$currentMonth"
  local logFile="$logDir/${currentDate}.csv"

  mkdir -p "$logDir"

  # Add header if log file doesn't exist, no fix for special characters needed, as the header will never have those.
  if [ ! -f "$logFile" ]; then
    printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
      "Date" \
      "Time" \
      "NºDevices" \
      "Serial" \
      "Version Oculus" \
      "Battery %" \
      "Fast Charging?" \
      "Screen State" \
      "Device State" \
      "Game closed?" \
      "Rilix Board" \
      "Arduino Programmer" \
      "Arduino Port" \
      "Arduino Type" \
      "Default Output" \
      "Volume" \
      "TeamViewer Assigned?" \
      "AnydeskID state" \
      "Database TeamViewer ID" \
      "Database KEY" \
      "Database Country" \
      "Max Charging Current" \
      "Max Charging Voltage" \
      "Charge Counter" \
      "Battery Health %" \
      "PID quest" \
      "%CPU quest" \
      "%MEM quest" \
      "ARGS quest" \
      "PC CPU Temp" \
      "PC CPU Frequency" \
      "PC CPU Load" \
      "quest CPU Temp 1" \
      "quest CPU Temp 2" \
      "quest MD1 Temp" \
      "quest IO Chip Temp" \
      "License Key" \
      "License Label" \
      "License Activation ID" \
      "License Serial MB" \
      "License Serial Disk" \
      "License Serial HW" > "$logFile"
  fi
  # Count the number of lines written for this serial at the current date and time
  linesAlreadyWritten=$(count_lines_written_for_serial "$logFile" "$SERIAL" "$currentDate" "$currentTime")

  # Calculate the number of lines to write for CSV
  linesToWriteCSV=$((3 - linesAlreadyWritten))
  
  # ALWAYS collect 3 lines of data to send to Heroku (independent of CSV)
  linesToCollectForHeroku=3
  shouldWriteToCSV=true
  
  if [ "$linesToWriteCSV" -le 0 ]; then
    echo "Lines already written for serial ($SERIAL) at $currentDate $currentTime, skipping CSV write but collecting data for Heroku."
    shouldWriteToCSV=false
    linesToWriteCSV=0
  fi

  # Capture Oculus version information with error handling
  versionOculus=$(adb -s "$SERIAL" shell dumpsys package com.oculus.systemdriver | grep versionName | awk -F "=" '{print $2}' 2>/dev/null | head -1)
  versionOculus=${versionOculus:-"N/A"}

  # Capture various details from device with error handling
  adbInfo=$(adb -s "$SERIAL" shell '
    dumpsys battery | grep level | awk "{print \$2}" 2>/dev/null;  # Battery Level
    dumpsys power | grep mWakefulness= | awk -F "=" "{print \$2}" 2>/dev/null;  # Screen State
    cat sys/class/thermal/thermal_zone2/temp 2>/dev/null;  # CPU Temp 1
    cat sys/class/thermal/thermal_zone5/temp 2>/dev/null;  # CPU Temp 2
    cat sys/class/thermal/thermal_zone4/temp 2>/dev/null;  # MD1 Temp
    cat sys/class/thermal/thermal_zone3/temp 2>/dev/null;  # IO Chip Temp
    dumpsys battery | grep "Max charging current:" | awk -F ": " "{print \$2}" 2>/dev/null;  # Max Charging Current
    dumpsys battery | grep "Max charging voltage:" | awk -F ": " "{print \$2}" 2>/dev/null;  # Max Charging Voltage
    dumpsys battery | grep "Charge counter:" | awk -F ": " "{print \$2}" 2>/dev/null;  # Charge Counter
  ' 2>/dev/null)

  # Parse captured information with fallbacks
  batteryStatus=$(echo "$adbInfo" | sed -n '1p' | head -1)
  batteryStatus=${batteryStatus:-"N/A"}
  
  screenState=$(echo "$adbInfo" | sed -n '2p' | head -1)
  screenState=${screenState:-"N/A"}
  
  # Temperature calculations with error handling
  temp1_raw=$(echo "$adbInfo" | sed -n '3p' | head -1)
  temp2_raw=$(echo "$adbInfo" | sed -n '4p' | head -1)
  temp3_raw=$(echo "$adbInfo" | sed -n '5p' | head -1)
  temp4_raw=$(echo "$adbInfo" | sed -n '6p' | head -1)
  
  if [[ "$temp1_raw" =~ ^[0-9]+$ ]] && [ "$temp1_raw" -gt 0 ]; then
    cpuTemp1=$(echo "scale=1; $temp1_raw / 1000" | bc 2>/dev/null)
  else
    cpuTemp1="N/A"
  fi
  
  if [[ "$temp2_raw" =~ ^[0-9]+$ ]] && [ "$temp2_raw" -gt 0 ]; then
    cpuTemp2=$(echo "scale=1; $temp2_raw / 1000" | bc 2>/dev/null)
  else
    cpuTemp2="N/A"
  fi
  
  if [[ "$temp3_raw" =~ ^[0-9]+$ ]] && [ "$temp3_raw" -gt 0 ]; then
    md1Temp=$(echo "scale=1; $temp3_raw / 1000" | bc 2>/dev/null)
  else
    md1Temp="N/A"
  fi
  
  if [[ "$temp4_raw" =~ ^[0-9]+$ ]] && [ "$temp4_raw" -gt 0 ]; then
    ioChipTemp=$(echo "scale=1; $temp4_raw / 1000" | bc 2>/dev/null)
  else
    ioChipTemp="N/A"
  fi
  
  maxChargingCurrent=$(echo "$adbInfo" | sed -n '7p' | head -1)
  maxChargingCurrent=${maxChargingCurrent:-"N/A"}
  
  maxChargingVoltage=$(echo "$adbInfo" | sed -n '8p' | head -1)
  maxChargingVoltage=${maxChargingVoltage:-"N/A"}
  
  chargeCounter=$(echo "$adbInfo" | sed -n '9p' | head -1)
  chargeCounter=${chargeCounter:-"N/A"}
  

  # Capture PC data
  capture_pc_data

  # Calculate battery health with error handling
  if [[ "$chargeCounter" != "N/A" ]] && [[ "$batteryStatus" != "N/A" ]]; then
    batteryHealth=$(calculate_battery_health "$chargeCounter" "$batteryStatus" 2>/dev/null)
    batteryHealth=${batteryHealth:-"N/A"}
  else
    batteryHealth="N/A"
  fi

  # Check for Fast Charging with error handling
  if [[ "$maxChargingCurrent" != "N/A" ]]; then
    check_fast_charging
  else
    fastChargingState="N/A"
  fi

  # Capture top output for processes - ALWAYS 3 lines for Heroku
  topOutput=$(adb -s "$SERIAL" shell top -b -n 1 -o %CPU,%MEM,PID,ARGS 2>/dev/null)

  # Filter top output to only include CPU, MEM, PID, and ARGS for Heroku collection
  echo "$topOutput" | awk 'NR>7 {print $3 "," $1 "," $2 "," $4}' | sort -t ',' -k2,2nr | head -n "$linesToCollectForHeroku" > "$tempFile"

  # Get the number of connected devices
  numConnectedDevices=$(adb devices | awk 'NR>1 && $2=="device"' | wc -l)

  # Check multiple functions with error handling
  get_database_monitoring_entries || echo "Warning: database_monitoring_entries failed" >&2
  get_device_state || echo "Warning: get_device_state failed" >&2
  get_is_game_closed || echo "Warning: get_is_game_closed failed" >&2
  get_default_output_volume || echo "Warning: get_default_output_volume failed" >&2
  get_is_tv_default_output || echo "Warning: get_is_tv_default_output failed" >&2
  get_is_arduino_programmer_mkii || echo "Warning: get_is_arduino_programmer_mkii failed" >&2
  get_is_arduino_board_micro || echo "Warning: get_is_arduino_board_micro failed" >&2
  get_is_teamviewer_assigned || echo "Warning: get_is_teamviewer_assigned failed" >&2
  get_is_arduino_correct_port || echo "Warning: get_is_arduino_correct_port failed" >&2
  get_is_anydesk_id_duplicated || echo "Warning: get_is_anydesk_id_duplicated failed" >&2

  # Initialize variables with defaults if not set
  deviceState=${deviceState:-"N/A"}
  isGameClosed=${isGameClosed:-"N/A"}
  rilixBoardStatus=${rilixBoardStatus:-"N/A"}
  arduinoProgrammer=${arduinoProgrammer:-"N/A"}
  isArduinoCorrectPort=${isArduinoCorrectPort:-"N/A"}
  isArduinoBoardMicro=${isArduinoBoardMicro:-"N/A"}
  isTvDefaultOutput=${isTvDefaultOutput:-"N/A"}
  defaultOutputVolume=${defaultOutputVolume:-"N/A"}
  isTeamViewerAssigned=${isTeamViewerAssigned:-"N/A"}
  isAnydeskIdDuplicated=${isAnydeskIdDuplicated:-"N/A"}
  databaseMonitoringTeamviewerName=${databaseMonitoringTeamviewerName:-"N/A"}
  databaseMonitoringKey=${databaseMonitoringKey:-"N/A"}
  databaseMonitoringCountry=${databaseMonitoringCountry:-"N/A"}
  pcCpuTemp=${pcCpuTemp:-"N/A"}
  pcCpuFreq=${pcCpuFreq:-"N/A"}
  pcCpuLoad=${pcCpuLoad:-"N/A"}

  # Process each line - ALWAYS send data to Heroku
  numLines=0
  numCSVLines=0
  
  while IFS= read -r process && [ $numLines -lt "$linesToCollectForHeroku" ]; do
    IFS=',' read -r PID CPU MEM ARGS <<< "$process"
    
    # Sanitize process data
    PID=${PID:-"N/A"}
    CPU=${CPU:-"N/A"}
    MEM=${MEM:-"N/A"}
    ARGS=${ARGS:-"N/A"}
    
    # Remove any problematic characters for JSON
    PID=$(echo "$PID" | tr -d '"' | head -c 20)
    CPU=$(echo "$CPU" | tr -d '"' | head -c 10)
    MEM=$(echo "$MEM" | tr -d '"' | head -c 10)
    ARGS=$(echo "$ARGS" | tr -d '"' | head -c 100)
    
    # Write to CSV only if needed and within limit
    if [ "$shouldWriteToCSV" = true ] && [ $numCSVLines -lt $linesToWriteCSV ]; then
      printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
        "$currentDate" "$currentTime" "$numConnectedDevices" "$SERIAL" "$versionOculus" "$batteryStatus" "$fastChargingState" "$screenState" "$deviceState" "$isGameClosed" "$rilixBoardStatus" "$arduinoProgrammer" "$isArduinoCorrectPort" "$isArduinoBoardMicro" "$isTvDefaultOutput" "$(fix_csv_inner_quoting "$defaultOutputVolume")" "$isTeamViewerAssigned" "$isAnydeskIdDuplicated" "$(fix_csv_inner_quoting "$databaseMonitoringTeamviewerName")" "$(fix_csv_inner_quoting "$databaseMonitoringKey")" "$(fix_csv_inner_quoting "$databaseMonitoringCountry")" "$maxChargingCurrent" "$maxChargingVoltage" "$chargeCounter" "$batteryHealth" "$PID" "$CPU" "$MEM" "$(fix_csv_inner_quoting "$ARGS")" "$pcCpuTemp" "$pcCpuFreq" "$pcCpuLoad" "$cpuTemp1" "$cpuTemp2" "$md1Temp" "$ioChipTemp" "$(fix_csv_inner_quoting "$licenseKey")" "$(fix_csv_inner_quoting "$licenseLabel")" "$(fix_csv_inner_quoting "$licenseActivationId")" "$(fix_csv_inner_quoting "$licenseSerialMotherboard")" "$(fix_csv_inner_quoting "$licenseSerialDisk")" "$(fix_csv_inner_quoting "$licenseSerialHardware")" >> "$logFile"
      ((numCSVLines++))
    fi
    
    # ALWAYS prepare and send data to Heroku using dedicated function
    local json_data=$(create_json_payload \
      "$currentDate" "$currentTime" "$numConnectedDevices" "$SERIAL" "$versionOculus" \
      "$batteryStatus" "$fastChargingState" "$screenState" "$deviceState" \
      "$isGameClosed" "$rilixBoardStatus" "$arduinoProgrammer" "$isArduinoCorrectPort" \
      "$isArduinoBoardMicro" "$isTvDefaultOutput" "$defaultOutputVolume" "$isTeamViewerAssigned" \
      "$isAnydeskIdDuplicated" "$databaseMonitoringTeamviewerName" "$databaseMonitoringKey" \
      "$databaseMonitoringCountry" "$maxChargingCurrent" "$maxChargingVoltage" "$chargeCounter" \
      "$batteryHealth" "$PID" "$CPU" "$MEM" "$ARGS" "$pcCpuTemp" "$pcCpuFreq" "$pcCpuLoad" \
      "$cpuTemp1" "$cpuTemp2" "$md1Temp" "$ioChipTemp" "$licenseKey" "$licenseLabel" \
      "$licenseActivationId" "$licenseSerialMotherboard" "$licenseSerialDisk" "$licenseSerialHardware")
    
    # Log JSON preview for debugging
    echo "JSON Preview: ${json_data:0:300}..." >> /tmp/heroku_debug.log
    
    # ALWAYS send data to Heroku
    send_data_to_heroku "$json_data"
    
    ((numLines++))
  done < "$tempFile"

  # If there are no processes in tempFile, send at least 1 basic record
  if [ $numLines -eq 0 ]; then
    echo "No process data found, sending basic device data to Heroku" >> /tmp/heroku_debug.log
    
    local json_data=$(create_json_payload \
      "$currentDate" "$currentTime" "$numConnectedDevices" "$SERIAL" "$versionOculus" \
      "$batteryStatus" "$fastChargingState" "$screenState" "$deviceState" \
      "$isGameClosed" "$rilixBoardStatus" "$arduinoProgrammer" "$isArduinoCorrectPort" \
      "$isArduinoBoardMicro" "$isTvDefaultOutput" "$defaultOutputVolume" "$isTeamViewerAssigned" \
      "$isAnydeskIdDuplicated" "$databaseMonitoringTeamviewerName" "$databaseMonitoringKey" \
      "$databaseMonitoringCountry" "$maxChargingCurrent" "$maxChargingVoltage" "$chargeCounter" \
      "$batteryHealth" "N/A" "N/A" "N/A" "N/A" "$pcCpuTemp" "$pcCpuFreq" "$pcCpuLoad" \
      "$cpuTemp1" "$cpuTemp2" "$md1Temp" "$ioChipTemp" "$licenseKey" "$licenseLabel" \
      "$licenseActivationId" "$licenseSerialMotherboard" "$licenseSerialDisk" "$licenseSerialHardware")
    
    send_data_to_heroku "$json_data"
    numLines=1
  fi

  # Remove temporary file
  rm -f "$tempFile"

  if [ "$shouldWriteToCSV" = true ]; then
    echo "Captured $numCSVLines CSV entries and sent $numLines data entries for $SERIAL to Heroku"
  else
    echo "Sent $numLines data entries for $SERIAL to Heroku (CSV write skipped - already written)"
  fi
}

# Main function that runs log capture based on connected devices
main() {
  # Initialize debug log
  echo "$(date): ==================================" >> /tmp/heroku_debug.log
  echo "$(date): Starting Rilix Stats Collection" >> /tmp/heroku_debug.log
  
  # Test Heroku connectivity first
  if ! test_heroku_connectivity; then
    echo "$(date): Warning - Heroku connectivity test failed, but continuing..." >> /tmp/heroku_debug.log
  fi
  
  # Get list of connected devices
  deviceListStateDevice=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
  deviceListStateUnauthorized=$(adb devices | awk 'NR > 1 && $2 == "unauthorized" { print $1 }')
  
  echo "$(date): Connected devices: $(echo $deviceListStateDevice | wc -w)" >> /tmp/heroku_debug.log
  echo "$(date): Unauthorized devices: $(echo $deviceListStateUnauthorized | wc -w)" >> /tmp/heroku_debug.log
  
  if [[ -z "$deviceListStateDevice" || -n "$deviceListStateUnauthorized" ]]; then
    echo "$(date): No valid devices found, creating placeholder entry" >> /tmp/heroku_debug.log
    create_placeholder_entry
  else
    for deviceSerial in $deviceListStateDevice; do
      echo "$(date): Processing device: $deviceSerial" >> /tmp/heroku_debug.log
      capture_logs "cpu" "$deviceSerial"
    done
  fi
  
  echo "$(date): Rilix Stats Collection completed" >> /tmp/heroku_debug.log
}

# Run the main function
main
EOF

# Step 5: Set the script permissions
log "Setting permissions for $scriptPath..."
sudo chmod +x "$scriptPath"

# Step 6: Configure cron to run the script every 2 hours
log "Setting up cron job to run the script every 2 hours..."
cronCmd="0 */2 * * * $scriptPath"

# First, check if the cron job is already set
if sudo crontab -l 2>/dev/null | grep -q "$scriptPath"; then
  log "Cron job for $scriptPath already exists."
else
  # Try adding the cron job
  (sudo crontab -l 2>/dev/null; echo "$cronCmd") | sudo crontab - || die "Failed to add cron job"
  log "Cron job successfully added."
fi

printf "${YELLOW}# Installation completed successfully!${NC}\n"
