#!/bin/sh
##############################################################################
# DDoS-Deflate Original Author: Zaf <zaf@vsnl.com>                           #
##############################################################################
# Contributors:                                                              #
# Jefferson González <jgmdev@gmail.com>                                      #
# Marc S. Brooks <devel@mbrooks.info>                                        #
##############################################################################
# This program is distributed under the "Artistic License" Agreement         #
#                                                                            #
# The LICENSE file is located in the same directory as this program. Please  #
# read the LICENSE file before you make copies or distribute this program    #
##############################################################################

CONF_PATH="/etc/ddos"
CONF_PATH="${CONF_PATH}/"

# Other variables
BANS_IP_LIST="/var/lib/ddos/bans.list"
SERVER_IP_LIST=$(ifconfig | \
    grep -E "inet6? " | \
    sed "s/addr: /addr:/g" | \
    awk '{print $2}' | \
    sed -E "s/addr://g" | \
    sed -E "s/\\/[0-9]+//g"
)
SERVER_IP4_LIST=$(ifconfig | \
    grep -E "inet " | \
    sed "s/addr: /addr:/g" | \
    awk '{print $2}' | \
    sed -E "s/addr://g" | \
    sed -E "s/\\/[0-9]+//g" | \
    grep -v "127.0.0.1"
)
SERVER_IP6_LIST=$(ifconfig | \
    grep -E "inet6 " | \
    sed "s/addr: /addr:/g" | \
    awk '{print $2}' | \
    sed -E "s/addr://g" | \
    sed -E "s/\\/[0-9]+//g" | \
    grep -v "::1"
)

load_conf()
{
    CONF="${CONF_PATH}ddos.conf"
    if [ -f "$CONF" ] && [ -n "$CONF" ]; then
        . $CONF
    else
        head
        echo "\$CONF not found."
        exit 1
    fi
}

head()
{
    echo "DDoS-Deflate version 1.1"
    echo "Copyright (C) 2005, Zaf <zaf@vsnl.com>"
    echo
}

showhelp()
{
    head
    echo 'Usage: ddos [OPTIONS] [N]'
    echo 'N : number of tcp/udp connections (default '"$NO_OF_CONNECTIONS"')'
    echo
    echo 'OPTIONS:'
    echo '-h      | --help: Show this help screen'
    echo '-c      | --cron: Create cron job to run this script regularly (default 1 mins)'
    echo '-i      | --ignore-list: List whitelisted ip addresses'
    echo '-b      | --bans-list: List currently banned ip addresses.'
    echo '-u      | --unban: Unbans a given ip address.'
    echo '-d      | --start: Initialize a daemon to monitor connections'
    echo '-s      | --stop: Stop the daemon'
    echo '-t      | --status: Show status of daemon and pid if currently running'
    echo '-v[4|6] | --view [4|6]: Display active connections to the server'
    echo '-y[4|6] | --view-port [4|6]: Display active connections to the server including the port'
    echo '-k      | --kill: Block all ip addresses making more than N connections'
}

# Check if super user is executing the
# script and exit with message if not.
su_required()
{
    user_id=$(id -u)

    if [ "$user_id" != "0" ]; then
        echo "You need super user priviliges for this."
        exit
    fi
}

log_msg()
{
    if [ ! -e /var/log/ddos.log ]; then
        touch /var/log/ddos.log
        chmod 0640 /var/log/ddos.log
    fi

    echo "$(date +'[%Y-%m-%d %T]') $1" >> /var/log/ddos.log
}

# Gets a list of ip address to ignore with hostnames on the
# ignore.host.list resolved to ip numbers
# param1 can be set to 1 to also include the bans list
ignore_list()
{
    for the_host in $(grep -v "#" "${CONF_PATH}${IGNORE_HOST_LIST}"); do
        host_ip=$(nslookup "$the_host" | tail -n +3 | grep "Address" | awk '{print $2}')

        # In case an ip is given instead of hostname
        # in the ignore.hosts.list file
        if [ "$host_ip" = "" ]; then
            echo "$the_host"
        else
            for ips in $host_ip; do
                echo "$ips"
            done
        fi
    done

    # Get ip's of ethernet interfaces to prevent blocking it self.
    #for iface_ip in $(ifconfig | grep "inet " | awk '{print $2}' | sed "s/addr://g"); do
    #    echo $iface_ip
    #done

    grep -v "#" "${CONF_PATH}${IGNORE_IP_LIST}"

    if [ "$1" = "1" ]; then
        cut -d" " -f2 "${BANS_IP_LIST}"
    fi
}

# Bans a given ip using autodetected firewall or
# ip6tables for ipv6 connections.
# param1 The ip address to block
ban_ip()
{
    if ! echo "$1" | grep ":">/dev/null; then
        if [ "$FIREWALL" = "apf" ]; then
            $APF -d "$1"
        elif [ "$FIREWALL" = "csf" ]; then
            $CSF -d "$1"
        elif [ "$FIREWALL" = "ipfw" ]; then
            rule_number=$(ipfw list | tail -1 | awk '/deny/{print $1}')
            next_number=$((rule_number + 1))
            $IPF -q add "$next_number" deny all from "$1" to any
        elif [ "$FIREWALL" = "iptables" ]; then
            $IPT -I INPUT -s "$1" -j DROP
        fi
    else
        ip6tables -I INPUT -s "$1" -j DROP
    fi
}

# Unbans an ip.
# param1 The ip address
# param2 Optional amount of connections the unbanned ip did.
unban_ip()
{
    if [ "$1" = "" ]; then
        return 1
    fi

    if ! echo "$1" | grep ":">/dev/null; then
        if [ "$FIREWALL" = "apf" ]; then
            $APF -u "$1"
        elif [ "$FIREWALL" = "csf" ]; then
            $CSF -dr "$1"
        elif [ "$FIREWALL" = "ipfw" ]; then
            rule_number=$($IPF list | awk "/$1/{print $1}")
            $IPF -q delete "$rule_number"
        elif [ "$FIREWALL" = "iptables" ]; then
            $IPT -D INPUT -s "$1" -j DROP
        fi
    else
        ip6tables -D INPUT -s "$1" -j DROP
    fi

    if [ "$2" != "" ]; then
        log_msg "unbanned $1 that opened $2 connections"
    else
        log_msg "unbanned $1"
    fi

    grep -v "$1" "${BANS_IP_LIST}" > "${BANS_IP_LIST}.tmp"
    rm "${BANS_IP_LIST}"
    mv "${BANS_IP_LIST}.tmp" "${BANS_IP_LIST}"

    return 0
}

# Unbans ip's after the amount of time given on BAN_PERIOD
unban_ip_list()
{
    current_time=$(date +"%s")

    while read line; do
        if [ "$line" = "" ]; then
            continue
        fi

        ban_time=$(echo "$line" | cut -d" " -f1)
        ip=$(echo "$line" | cut -d" " -f2)
        connections=$(echo "$line" | cut -d" " -f3)

        if [ "$current_time" -gt "$ban_time" ]; then
            unban_ip "$ip" "$connections"
        fi
    done < $BANS_IP_LIST
}

add_to_cron()
{
    su_required

    echo "Warning: this feature is deprecated and ddos-deflate should" \
         "be run on daemon mode instead."

    if [ "$FREQ" -gt 59 ]; then
        FREQ=1
    fi

    # since this string contains * it is needed to double quote the
    # variable when using it or the * will be evaluated by the shell
    cron_task="*/$FREQ * * * * root $SBINDIR/ddos -k > /dev/null 2>&1"

    if [ "$FIREWALL" = "ipfw" ]; then
        cron_file=/etc/crontab
        sed -i '' '/ddos/d' "$cron_file"
        echo "$cron_task" >> "$cron_file"
    else
        rm -f "$CRON"
        echo "$cron_task" > "$CRON"
        chmod 644 "$CRON"
    fi

    log_msg "added cron job"
}

ban_incoming_and_outgoing()
{
    whitelist=$(ignore_list "1")

    # Find all connections
    ss -Hntu state $(echo "$CONN_STATES" | sed 's/:/ state /g') | \
        # Extract the client ip
        awk '{print $6}' | \
        # Strip port and [ ] brackets
        sed -E "s/\\[//g; s/\\]//g; s/:[0-9]+$//g" | \
        # Only leave non whitelisted, we add ::1 to ensure -v works for ipv6
        grepcidr -v -e "$SERVER_IP_LIST $whitelist ::1" | \
        # Sort addresses for uniq to work correctly
        sort | \
        # Group same occurrences of ip and prepend amount of occurences found
        uniq -c | \
        # sort by number of connections
        sort -nr | \
        # Only store connections that exceed max allowed
        awk "{ if (\$1 >= $NO_OF_CONNECTIONS) print; }" > \
        "$1"
}

ban_only_incoming()
{
    whitelist=$(ignore_list "1")

    ALL_LISTENING=$(mktemp "$TMP_PREFIX".XXXXXXXX)
    ALL_LISTENING_FULL=$(mktemp "$TMP_PREFIX".XXXXXXXX)
    ALL_CONNS=$(mktemp "$TMP_PREFIX".XXXXXXXX)
    ALL_SERVER_IP=$(mktemp "$TMP_PREFIX".XXXXXXXX)
    ALL_SERVER_IP6=$(mktemp "$TMP_PREFIX".XXXXXXXX)

    # Find all connections
    ss -Hntu state $(echo "$CONN_STATES" | sed 's/:/ state /g') | \
        # Extract both local and foreign address:port
        awk '{print $5" "$6;}' > \
        "$ALL_CONNS"

    # Find listening connections
    ss -Hntu state listening | \
        # Only keep local address:port
        awk '{print $4}' > \
        "$ALL_LISTENING"

    # Also append all server addresses when address is 0.0.0.0 or [::]
    echo "$SERVER_IP4_LIST" > "$ALL_SERVER_IP"
    echo "$SERVER_IP6_LIST" > "$ALL_SERVER_IP6"

    awk '
    FNR == 1 { ++fIndex }
    fIndex == 1{ip_list[$1];next}
    fIndex == 2{ip6_list[$1];next}
    {
        ip_pos = index($0, "0.0.0.0");
        ip6_pos = index($0, "[::]");
        if (ip_pos != 0) {
            port_pos = index($0, ":");
            print $0;
            for (ip in ip_list){
                print ip substr($0, port_pos);
            }
        } else if (ip6_pos != 0) {
            port_pos = index($0, "]:");
            print $0;
            for (ip in ip6_list){
                print "[" ip substr($0, port_pos);
            }
        } else {
            print $0;
        }
    }
    ' "$ALL_SERVER_IP" "ALL_SERVER_IP6" "$ALL_LISTENING" > "$ALL_LISTENING_FULL"

    # Only keep connections which are connected to local listening service
    awk 'NR==FNR{a[$1];next} $1 in a {print $2}' "$ALL_LISTENING_FULL" "$ALL_CONNS" | \
        # Strip port and [ ] brackets
        sed -E "s/\\[//g; s/\\]//g; s/:[0-9]+$//g" | \
        # Only leave non whitelisted, we add ::1 to ensure -v works
        grepcidr -v -e "$SERVER_IP_LIST $whitelist ::1" | \
        # Sort addresses for uniq to work correctly
        sort | \
        # Group same occurrences of ip and prepend amount of occurences found
        uniq -c | \
        # Numerical sort in reverse order
        sort -nr | \
        # Only store connections that exceed max allowed
        awk "{ if (\$1 >= $NO_OF_CONNECTIONS) print; }" > \
        "$1"

    # remove temp files
    rm "$ALL_LISTENING"
    rm "$ALL_LISTENING_FULL"
    rm "$ALL_CONNS"
    rm "$ALL_SERVER_IP"
    rm "$ALL_SERVER_IP6"
}

# Check active connections and ban if neccessary.
check_connections()
{
    su_required

    TMP_PREFIX='/tmp/ddos'
    TMP_FILE="mktemp $TMP_PREFIX.XXXXXXXX"
    BAD_IP_LIST=$($TMP_FILE)

    if $ONLY_INCOMING; then
        ban_only_incoming "$BAD_IP_LIST"
    else
        ban_incoming_and_outgoing "$BAD_IP_LIST"
    fi

    FOUND=$(cat "$BAD_IP_LIST")

    if [ "$FOUND" = "" ]; then
        rm -f "$BAD_IP_LIST"

        if [ "$KILL" -eq 1 ]; then
            echo "No connections exceeding max allowed."
        fi

        return 0
    fi

    if [ "$KILL" -eq 1 ]; then
        echo "List of connections that exceed max allowed"
        echo "==========================================="
        cat "$BAD_IP_LIST"
    fi

    BANNED_IP_MAIL=$($TMP_FILE)
    BANNED_IP_LIST=$($TMP_FILE)

    echo "Banned the following ip addresses on $(date)" > "$BANNED_IP_MAIL"
    echo >> "$BANNED_IP_MAIL"

    IP_BAN_NOW=0

    while read line; do
        CURR_LINE_CONN=$(echo "$line" | cut -d" " -f1)
        CURR_LINE_IP=$(echo "$line" | cut -d" " -f2)

        IP_BAN_NOW=1

        echo "$CURR_LINE_IP with $CURR_LINE_CONN connections" >> "$BANNED_IP_MAIL"
        echo "$CURR_LINE_IP" >> "$BANNED_IP_LIST"

        current_time=$(date +"%s")
        echo "$((current_time+BAN_PERIOD)) ${CURR_LINE_IP} ${CURR_LINE_CONN}" >> "${BANS_IP_LIST}"

        # execute tcpkill for 60 seconds
        timeout -k 60 -s 9 60 \
            tcpkill -9 host "$CURR_LINE_IP" > /dev/null 2>&1 &

        ban_ip "$CURR_LINE_IP"

        log_msg "banned $CURR_LINE_IP with $CURR_LINE_CONN connections for ban period $BAN_PERIOD"
    done < "$BAD_IP_LIST"

    if [ "$IP_BAN_NOW" -eq 1 ]; then
        if [ -n "$EMAIL_TO" ]; then
            dt=$(date)
            hn=$(hostname)
            cat "$BANNED_IP_MAIL" | mail -s "[$hn] IP addresses banned on $dt" $EMAIL_TO
        fi

        if [ "$KILL" -eq 1 ]; then
            echo "==========================================="
            echo "Banned IP addresses:"
            echo "==========================================="
            cat "$BANNED_IP_LIST"
        fi
    fi

    rm -f "$TMP_PREFIX".*
}

# Active connections to server.
view_connections()
{
    ip6_show=false
    ip4_show=false

    if [ "$1" = "6" ]; then
        ip6_show=true
    elif [ "$1" = "4" ]; then
        ip4_show=true
    else
        ip6_show=true
        ip4_show=true
    fi

    whitelist=$(ignore_list "1")

    # Find all ipv4 connections
    if $ip4_show; then
        ss -4Hntu state $(echo "$CONN_STATES" | sed 's/:/ state /g') | \
            # Extract only the fifth column
            awk '{print $6}' | \
            # Strip port
            cut -d":" -f1 | \
            # Sort addresses for uniq to work correctly
            sort | \
            # Only leave non whitelisted
            grepcidr -v -e "$SERVER_IP_LIST $whitelist" | \
            # Group same occurrences of ip and prepend amount of occurences found
            uniq -c | \
            # Numerical sort in reverse order
            sort -nr
    fi

    # Find all ipv6 connections
    if $ip6_show; then
        ss -6Hntu state $(echo "$CONN_STATES" | sed 's/:/ state /g') | \
            # Extract only the fifth column
            awk '{print $6}' | \
            # Strip port and leading [
            sed -E "s/]:[0-9]+//g" | sed "s/\\[//g" | \
            # Sort addresses for uniq to work correctly
            sort | \
            # Only leave non whitelisted, we add ::1 to ensure -v works
            grepcidr -v -e "$SERVER_IP_LIST $whitelist ::1" | \
            # Group same occurrences of ip and prepend amount of occurences found
            uniq -c | \
            # Numerical sort in reverse order
            sort -nr
    fi
}

# Active connections to server including port.
view_connections_port()
{
    ip6_show=false
    ip4_show=false

    if [ "$1" = "6" ]; then
        ip6_show=true
    elif [ "$1" = "4" ]; then
        ip4_show=true
    else
        ip6_show=true
        ip4_show=true
    fi

    whitelist=$(ignore_list "1")

    # Find all ipv4 connections
    if $ip4_show; then
        ss -4Hntu state $(echo "$CONN_STATES" | sed 's/:/ state /g') | \
            # Extract only the fifth column
            awk '{print $6}' | \
            # Sort addresses for uniq to work correctly
            sort | \
            # Only leave non whitelisted
            grepcidr -v -e "$SERVER_IP_LIST $whitelist" | \
            # Group same occurrences of ip and prepend amount of occurences found
            uniq -c | \
            # Numerical sort in reverse order
            sort -nr
    fi

    # Find all ipv6 connections
    if $ip6_show; then
        ss -6Hntu state $(echo "$CONN_STATES" | sed 's/:/ state /g') | \
            # Extract only the fifth column
            awk '{print $6}' | \
            # Strip leading [ and ending ]
            sed -E "s/(\\[|\\])//g" | \
            # Sort addresses for uniq to work correctly
            sort | \
            # Only leave non whitelisted, we add ::1 to ensure -v works
            grepcidr -v -e "$SERVER_IP_LIST $whitelist ::1" | \
            # Group same occurrences of ip and prepend amount of occurences found
            uniq -c | \
            # Numerical sort in reverse order
            sort -nr
    fi
}

# Executed as a cleanup function when the daemon is stopped
on_daemon_exit()
{
    if [ -e /var/run/ddos.pid ]; then
        rm -f /var/run/ddos.pid
    fi

    exit 0
}

# Return the current process id of the daemon or 0 if not running
daemon_pid()
{
    if [ -e "/var/run/ddos.pid" ]; then
        echo $(cat /var/run/ddos.pid)

        return
    fi

    echo "0"
}

# Check if daemon is running.
# Outputs 1 if running 0 if not.
daemon_running()
{
    if [ -e /var/run/ddos.pid ]; then
        running_pid=$(pgrep ddos)

        if [ "$running_pid" != "" ]; then
            current_pid=$(daemon_pid)

            for pid_num in $running_pid; do
                if [ "$current_pid" = "$pid_num" ]; then
                    echo "1"
                    return
                fi
            done
        fi
    fi

    echo "0"
}

start_daemon()
{
    su_required

    if [ "$(daemon_running)" = "1" ]; then
        echo "ddos daemon is already running..."
        exit 0
    fi

    echo "starting ddos daemon..."

    if [ ! -e "$BANS_IP_LIST" ]; then
        touch "${BANS_IP_LIST}"
    fi

    nohup "$0" -l > /dev/null 2>&1 &

    log_msg "daemon started"
}

stop_daemon()
{
    su_required

    if [ "$(daemon_running)" = "0" ]; then
        echo "ddos daemon is not running..."
        exit 0
    fi

    echo "stopping ddos daemon..."

    kill "$(daemon_pid)"

    while [ -e "/var/run/ddos.pid" ]; do
        continue
    done

    log_msg "daemon stopped"
}

daemon_loop()
{
    su_required

    if [ "$(daemon_running)" = "1" ]; then
        exit 0
    fi

    echo "$$" > "/var/run/ddos.pid"

    trap 'on_daemon_exit' INT
    trap 'on_daemon_exit' QUIT
    trap 'on_daemon_exit' TERM
    trap 'on_daemon_exit' EXIT

    detect_firewall

    # run unban_ip_list after 2 minutes of initialization
    ban_check_timer=$(date +"%s")
    ban_check_timer=$((ban_check_timer+120))

    while true; do
        check_connections

        # unban expired ip's every 1 minute
        current_loop_time=$(date +"%s")
        if [ "$current_loop_time" -gt "$ban_check_timer" ]; then
            unban_ip_list
            ban_check_timer=$(date +"%s")
            ban_check_timer=$((ban_check_timer+60))
        fi

        sleep "$DAEMON_FREQ"
    done
}

daemon_status()
{
    current_pid=$(daemon_pid)

    if [ "$(daemon_running)" = "1" ]; then
        echo "ddos status: running with pid $current_pid"
    else
        echo "ddos status: not running"
    fi
}

detect_firewall()
{
    if [ "$FIREWALL" = "auto" ] || [ "$FIREWALL" = "" ]; then
        apf_where=$(whereis apf);
        csf_where=$(whereis csf);
        ipf_where=$(whereis ipfw);
        ipt_where=$(whereis iptables);

        if [ -e "$APF" ]; then
            FIREWALL="apf"
        elif [ -e "$CSF" ]; then
            FIREWALL="csf"
        elif [ -e "$IPF" ]; then
            FIREWALL="ipfw"
        elif [ -e "$IPT" ]; then
            FIREWALL="iptables"
        elif [ "$apf_where" != "apf:" ]; then
            FIREWALL="apf"
            APF="apf"
        elif [ "$csf_where" != "csf:" ]; then
            FIREWALL="csf"
            CSF="csf"
        elif [ "$ipf_where" != "ipfw:" ]; then
            FIREWALL="ipfw"
            IPF="ipfw"
        elif [ "$ipt_where" != "iptables:" ]; then
            FIREWALL="iptables"
            IPT="iptables"
        else
            echo "error: No valid firewall found."
            log_msg "error: no valid firewall found"
            exit 1
        fi
    fi
}

view_ports()
{
    printf "Port blocking is: "

    if $ENABLE_PORTS; then
        printf "enabled\\n"
    else
        printf "disabled\\n"
    fi

    printf -- '-%.0s' $(seq 48); echo ""
    printf "% -15s % -15s % -15s\\n" "Port" "Max-Conn" "Ban-Time"
    printf -- '-%.0s' $(seq 48); echo ""
    for port in $(echo "$PORT_MAX_CONNECTIONS" | xargs); do
        number=$(echo "$port" | cut -d":" -f1)
        max_conn=$(echo "$port" | cut -d":" -f2)
        ban_time=$(echo "$port" | cut -d":" -f3)
        printf "% -15s % -15s % -15s\\n" $number $max_conn $ban_time
    done
}

# Set Default settings
PROGDIR="/usr/local/ddos"
SBINDIR="/usr/local/sbin"
PROG="$PROGDIR/ddos.sh"
IGNORE_IP_LIST="ignore.ip.list"
IGNORE_HOST_LIST="ignore.host.list"
CRON="/etc/cron.d/ddos"
APF="/usr/sbin/apf"
CSF="/usr/sbin/csf"
IPF="/sbin/ipfw"
IPT="/sbin/iptables"
FREQ=1
DAEMON_FREQ=5
NO_OF_CONNECTIONS=150
ENABLE_PORTS=false
PORT_MAX_CONNECTIONS="80:150:600 443:150:600"
FIREWALL="auto"
EMAIL_TO="root"
BAN_PERIOD=600
CONN_STATES="connected"
ONLY_INCOMING=false

# Load custom settings
load_conf

# Overwrite old configuration values
if echo "$CONN_STATES" | grep "|">/dev/null; then
    CONN_STATES="connected"
fi

KILL=0

while [ "$1" ]; do
    case $1 in
        '-h' | '--help' | '?' )
            showhelp
            exit
            ;;
        '--cron' | '-c' )
            add_to_cron
            exit
            ;;
        '--ignore-list' | '-i' )
            echo "List of currently whitelisted ip's."
            echo "==================================="
            ignore_list
            exit
            ;;
        '--bans-list' | '-b' )
            echo "List of currently banned ip's."
            echo "==================================="
            if [ -e "${BANS_IP_LIST}" ]; then
                cat "${BANS_IP_LIST}"
            fi
            exit
            ;;
        '--unban' | '-u' )
            su_required
            shift
            detect_firewall

            if ! unban_ip "$1"; then
                echo "Please specify a valid ip address."
            fi
            exit
            ;;
        '--start' | '-d' )
            start_daemon
            exit
            ;;
        '--stop' | '-s' )
            stop_daemon
            exit
            ;;
        '--status' | '-t' )
            daemon_status
            exit
            ;;
        '--loop' | '-l' )
            # start daemon loop, used internally by --start | -s
            daemon_loop
            exit
            ;;
        '--view' | '-v' )
            shift
            view_connections "$1"
            exit
            ;;
        '--view-port' | '-y' )
            shift
            view_connections_port "$1"
            exit
            ;;
        '-v6' | '-6v' )
            shift
            view_connections 6
            exit
            ;;
        '-y6' | '-6y' )
            shift
            view_connections_port 6
            exit
            ;;
        '-v4' | '-4v' )
            shift
            view_connections 4
            exit
            ;;
        '-y4' | '-4y' )
            shift
            view_connections_port 4
            exit
            ;;
        '--ports' | '-p' )
            view_ports
            exit
            ;;
        '--kill' | '-k' )
            su_required
            KILL=1
            ;;
         *[0-9]* )
            NO_OF_CONNECTIONS=$1
            ;;
        * )
            showhelp
            exit
            ;;
    esac

    shift
done

if [ $KILL -eq 1 ]; then
    detect_firewall
    check_connections
else
    showhelp
fi

exit 0
