#!/bin/sh 

#             DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
#                     Version 0, 2018

#  Copyright (C) 2018 Kabu Ihub

#  Everyone is permitted to copy and distribute verbatim or modified
#  copies of this license document, and changing it is allowed as long
#  as the name is changed.

#             DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
#    TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION

#   0. You just DO WHAT THE FUCK YOU WANT TO.

# Compiled for iptables (any version)
#
# the firewall is used as DHCP and DNS server for internal network.
# This firewall has two interfaces. Eth0 faces outside and has a dynamic address; eth1 faces inside.
# Policy includes basic rules to permit unrestricted outbound access and anti-spoofing rules. Access to the firewall is permitted only from internal network and only using SSH. The firewall can send DNS queries to servers out on the Internet. Another rule permits DNS queries from internal network to the firewall. Special rules permit DHCP requests from internal network and replies sent by the firewall.




FWBDEBUG=""

PATH="/sbin:/usr/sbin:/bin:/usr/bin:${PATH}"
export PATH



LSMOD="/sbin/lsmod"
MODPROBE="/sbin/modprobe"
IPTABLES="/sbin/iptables"
IP6TABLES="/sbin/ip6tables"
IPTABLES_RESTORE="/sbin/iptables-restore"
IP6TABLES_RESTORE="/sbin/ip6tables-restore"
IP="/sbin/ip"
IFCONFIG="/sbin/ifconfig"
VCONFIG="/sbin/vconfig"
BRCTL="/sbin/brctl"
IFENSLAVE="/sbin/ifenslave"
IPSET="/usr/sbin/ipset"
LOGGER="/usr/bin/logger"

log() {
    echo "$1"
    which "$LOGGER" >/dev/null 2>&1 && $LOGGER -p info "$1"
}

getInterfaceVarName() {
    echo $1 | sed 's/\./_/'
}

getaddr_internal() {
    dev=$1
    name=$2
    af=$3
    L=$($IP $af addr show dev $dev |  sed -n '/inet/{s!.*inet6* !!;s!/.*!!p}' | sed 's/peer.*//')
    test -z "$L" && { 
        eval "$name=''"
        return
    }
    eval "${name}_list=\"$L\"" 
}

getnet_internal() {
    dev=$1
    name=$2
    af=$3
    L=$($IP route list proto kernel | grep $dev | grep -v default |  sed 's! .*$!!')
    test -z "$L" && { 
        eval "$name=''"
        return
    }
    eval "${name}_list=\"$L\"" 
}


getaddr() {
    getaddr_internal $1 $2 "-4"
}

getaddr6() {
    getaddr_internal $1 $2 "-6"
}

getnet() {
    getnet_internal $1 $2 "-4"
}

getnet6() {
    getnet_internal $1 $2 "-6"
}

# function getinterfaces is used to process wildcard interfaces
getinterfaces() {
    NAME=$1
    $IP link show | grep ": $NAME" | while read L; do
        OIFS=$IFS
        IFS=" :"
        set $L
        IFS=$OIFS
        echo $2
    done
}

diff_intf() {
    func=$1
    list1=$2
    list2=$3
    cmd=$4
    for intf in $list1
    do
        echo $list2 | grep -q $intf || {
        # $vlan is absent in list 2
            $func $intf $cmd
        }
    done
}

find_program() {
  PGM=$1
  which $PGM >/dev/null 2>&1 || {
    echo "\"$PGM\" not found"
    exit 1
  }
}
check_tools() {
  find_program which
  find_program $IPTABLES 
  find_program $MODPROBE 
  find_program $IP 
}
reset_iptables_v4() {
  local list

  $IPTABLES  -P OUTPUT  DROP
  $IPTABLES  -P INPUT   DROP
  $IPTABLES  -P FORWARD DROP

  while read table; do
      list=$($IPTABLES  -t $table -L -n)
      printf "%s" "$list" | while read c chain rest; do
      if test "X$c" = "XChain" ; then
        $IPTABLES  -t $table -F $chain
      fi
      done
      $IPTABLES  -t $table -X
  done < /proc/net/ip_tables_names
}

reset_iptables_v6() {
  local list

  $IP6TABLES  -P OUTPUT  DROP
  $IP6TABLES  -P INPUT   DROP
  $IP6TABLES  -P FORWARD DROP

  while read table; do
      list=$($IP6TABLES  -t $table -L -n)
      printf "%s" "$list" | while read c chain rest; do
      if test "X$c" = "XChain" ; then
        $IP6TABLES  -t $table -F $chain
      fi
      done
      $IP6TABLES  -t $table -X
  done < /proc/net/ip6_tables_names
}


P2P_INTERFACE_WARNING=""

missing_address() {
    address=$1
    cmd=$2

    oldIFS=$IFS
    IFS="@"
    set $address
    addr=$1
    interface=$2
    IFS=$oldIFS



    $IP addr show dev $interface | grep -q POINTOPOINT && {
        test -z "$P2P_INTERFACE_WARNING" && echo "Warning: Can not update address of interface $interface. fwbuilder can not manage addresses of point-to-point interfaces yet"
        P2P_INTERFACE_WARNING="yes"
        return
    }

    test "$cmd" = "add" && {
      echo "# Adding ip address: $interface $addr"
      echo $addr | grep -q ':' && {
          $FWBDEBUG $IP addr $cmd $addr dev $interface
      } || {
          $FWBDEBUG $IP addr $cmd $addr broadcast + dev $interface
      }
    }

    test "$cmd" = "del" && {
      echo "# Removing ip address: $interface $addr"
      $FWBDEBUG $IP addr $cmd $addr dev $interface || exit 1
    }

    $FWBDEBUG $IP link set $interface up
}

list_addresses_by_scope() {
    interface=$1
    scope=$2
    ignore_list=$3
    $IP addr ls dev $interface | \
      awk -v IGNORED="$ignore_list" -v SCOPE="$scope" \
        'BEGIN {
           split(IGNORED,ignored_arr);
           for (a in ignored_arr) {ignored_dict[ignored_arr[a]]=1;}
         }
         (/inet |inet6 / && $0 ~ SCOPE && !($2 in ignored_dict)) {print $2;}' | \
        while read addr; do
          echo "${addr}@$interface"
	done | sort
}


update_addresses_of_interface() {
    ignore_list=$2
    set $1 
    interface=$1 
    shift

    FWB_ADDRS=$(
      for addr in $*; do
        echo "${addr}@$interface"
      done | sort
    )

    CURRENT_ADDRS_ALL_SCOPES=""
    CURRENT_ADDRS_GLOBAL_SCOPE=""

    $IP link show dev $interface >/dev/null 2>&1 && {
      CURRENT_ADDRS_ALL_SCOPES=$(list_addresses_by_scope $interface 'scope .*' "$ignore_list")
      CURRENT_ADDRS_GLOBAL_SCOPE=$(list_addresses_by_scope $interface 'scope global' "$ignore_list")
    } || {
      echo "# Interface $interface does not exist"
      # Stop the script if we are not in test mode
      test -z "$FWBDEBUG" && exit 1
    }

    diff_intf missing_address "$FWB_ADDRS" "$CURRENT_ADDRS_ALL_SCOPES" add
    diff_intf missing_address "$CURRENT_ADDRS_GLOBAL_SCOPE" "$FWB_ADDRS" del
}

clear_addresses_except_known_interfaces() {
    $IP link show | sed 's/://g' | awk -v IGNORED="$*" \
        'BEGIN {
           split(IGNORED,ignored_arr);
           for (a in ignored_arr) {ignored_dict[ignored_arr[a]]=1;}
         }
         (/state/ && !($2 in ignored_dict)) {print $2;}' | \
         while read intf; do
            echo "# Removing addresses not configured in fwbuilder from interface $intf"
            $FWBDEBUG $IP addr flush dev $intf scope global
            $FWBDEBUG $IP link set $intf down
         done
}

check_file() {
    test -r "$2" || {
        echo "Can not find file $2 referenced by address table object $1"
        exit 1
    }
}

check_run_time_address_table_files() {
    :
    
}

load_modules() {
    :
    OPTS=$1
    MODULES_DIR="/lib/modules/`uname -r`/kernel/net/"
    MODULES=$(find $MODULES_DIR -name '*conntrack*' \! -name '*ipv6*'|sed  -e 's/^.*\///' -e 's/\([^\.]\)\..*/\1/')
    echo $OPTS | grep -q nat && {
        MODULES="$MODULES $(find $MODULES_DIR -name '*nat*'|sed  -e 's/^.*\///' -e 's/\([^\.]\)\..*/\1/')"
    }
    echo $OPTS | grep -q ipv6 && {
        MODULES="$MODULES $(find $MODULES_DIR -name nf_conntrack_ipv6|sed  -e 's/^.*\///' -e 's/\([^\.]\)\..*/\1/')"
    }
    for module in $MODULES; do 
        if $LSMOD | grep ${module} >/dev/null; then continue; fi
        $MODPROBE ${module} ||  exit 1 
    done
}

verify_interfaces() {
    :
    echo "Verifying interfaces: eth0 eth1 lo"
    for i in eth0 eth1 lo ; do
        $IP link show "$i" > /dev/null 2>&1 || {
            log "Interface $i does not exist"
            exit 1
        }
    done
}

prolog_commands() {
    echo "Running prolog script"
    
}

epilog_commands() {
    echo "Running epilog script"
    
}

run_epilog_and_exit() {
    epilog_commands
    exit $1
}

configure_interfaces() {
    :
    # Configure interfaces
    update_addresses_of_interface "eth1 192.168.1.1/24" ""
    update_addresses_of_interface "lo 127.0.0.1/8" ""
    getaddr eth0  i_eth0
    getaddr6 eth0  i_eth0_v6
    getnet eth0  i_eth0_network
    getnet6 eth0  i_eth0_v6_network
}

script_body() {
    # ================ IPv4


    # ================ Table 'filter', automatic rules
    # accept established sessions
    $IPTABLES -A INPUT   -m state --state ESTABLISHED,RELATED -j ACCEPT 
    $IPTABLES -A OUTPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT 
    $IPTABLES -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT


    # ================ Table 'nat',  rule set NAT
    # 
    # Rule 0 (NAT)
    # 
    echo "Rule 0 (NAT)"
    # 
    $IPTABLES -t nat -A POSTROUTING -o eth0   -s 192.168.1.0/24  -j MASQUERADE



    # ================ Table 'filter', rule set Policy
    # 
    # Rule 0 (eth0)
    # 
    echo "Rule 0 (eth0)"
    # 
    # anti spoofing rule
    $IPTABLES -N In_RULE_0
    for i_eth0 in $i_eth0_list
    do
    test -n "$i_eth0" && $IPTABLES -A INPUT -i eth0   -s $i_eth0   -j In_RULE_0 
    done
    $IPTABLES -A INPUT -i eth0   -s 192.168.1.1   -j In_RULE_0
    $IPTABLES -A INPUT -i eth0   -s 192.168.1.0/24   -j In_RULE_0
    for i_eth0 in $i_eth0_list
    do
    test -n "$i_eth0" && $IPTABLES -A FORWARD -i eth0   -s $i_eth0   -j In_RULE_0 
    done
    $IPTABLES -A FORWARD -i eth0   -s 192.168.1.1   -j In_RULE_0
    $IPTABLES -A FORWARD -i eth0   -s 192.168.1.0/24   -j In_RULE_0
    $IPTABLES -A In_RULE_0  -j LOG  --log-level info --log-prefix "RULE 0 -- DENY "
    $IPTABLES -A In_RULE_0  -j DROP
    # 
    # Rule 1 (lo)
    # 
    echo "Rule 1 (lo)"
    # 
    $IPTABLES -A INPUT -i lo   -m state --state NEW  -j ACCEPT
    $IPTABLES -A OUTPUT -o lo   -m state --state NEW  -j ACCEPT
    # 
    # Rule 2 (global)
    # 
    echo "Rule 2 (global)"
    # 
    # SSH Access to firewall is permitted
    # only from internal network
    # Also firewall serves DNS for internal
    # network
    $IPTABLES -A INPUT -p tcp -m tcp  -m multiport  -s 192.168.1.0/24   --dports 53,22  -m state --state NEW  -j ACCEPT
    $IPTABLES -A INPUT -p udp -m udp  -s 192.168.1.0/24   --dport 53  -m state --state NEW  -j ACCEPT
    # 
    # Rule 3 (global)
    # 
    echo "Rule 3 (global)"
    # 
    # DHCP requests are permitted
    # from internal network
    $IPTABLES -A INPUT -p udp -m udp  -m multiport  -s 0.0.0.0   -d 255.255.255.255   --dports 68,67  -m state --state NEW  -j ACCEPT
    $IPTABLES -A OUTPUT -p udp -m udp  -m multiport  -s 0.0.0.0   -d 255.255.255.255   --dports 68,67  -m state --state NEW  -j ACCEPT
    $IPTABLES -A INPUT -p udp -m udp  -m multiport  -s 0.0.0.0   --dports 68,67  -m state --state NEW  -j ACCEPT
    $IPTABLES -N Cid4976X410.0
    $IPTABLES -A OUTPUT -p udp -m udp  -m multiport  -s 0.0.0.0   --dports 68,67  -m state --state NEW  -j Cid4976X410.0
    for i_eth0 in $i_eth0_list
    do
    test -n "$i_eth0" && $IPTABLES -A Cid4976X410.0  -d $i_eth0   -j ACCEPT 
    done
    $IPTABLES -A Cid4976X410.0  -d 192.168.1.1   -j ACCEPT
    $IPTABLES -A INPUT -p udp -m udp  -m multiport  -s 192.168.1.0/24   -d 255.255.255.255   --dports 68,67  -m state --state NEW  -j ACCEPT
    $IPTABLES -A INPUT -p udp -m udp  -m multiport  -s 192.168.1.0/24   --dports 68,67  -m state --state NEW  -j ACCEPT
    # 
    # Rule 4 (global)
    # 
    echo "Rule 4 (global)"
    # 
    # DHCP replies
    $IPTABLES -A OUTPUT -p udp -m udp  -m multiport  -d 192.168.1.0/24   --dports 68,67  -m state --state NEW  -j ACCEPT
    # 
    # Rule 5 (global)
    # 
    echo "Rule 5 (global)"
    # 
    # Firewall should be able to send
    # DNS queries to the Internet
    $IPTABLES -N Cid5034X410.0
    $IPTABLES -A INPUT -p tcp -m tcp  --dport 53  -m state --state NEW  -j Cid5034X410.0
    $IPTABLES -A INPUT -p udp -m udp  --dport 53  -m state --state NEW  -j Cid5034X410.0
    for i_eth0 in $i_eth0_list
    do
    test -n "$i_eth0" && $IPTABLES -A Cid5034X410.0  -s $i_eth0   -j ACCEPT 
    done
    $IPTABLES -A Cid5034X410.0  -s 192.168.1.1   -j ACCEPT
    $IPTABLES -A OUTPUT -p tcp -m tcp  --dport 53  -m state --state NEW  -j ACCEPT
    $IPTABLES -A OUTPUT -p udp -m udp  --dport 53  -m state --state NEW  -j ACCEPT
    # 
    # Rule 6 (global)
    # 
    echo "Rule 6 (global)"
    # 
    # All other attempts to connect to
    # the firewall are denied and logged
    $IPTABLES -N RULE_6
    for i_eth0 in $i_eth0_list
    do
    test -n "$i_eth0" && $IPTABLES -A OUTPUT  -d $i_eth0   -j RULE_6 
    done
    $IPTABLES -A OUTPUT  -d 192.168.1.1   -j RULE_6
    $IPTABLES -A INPUT  -j RULE_6
    $IPTABLES -A RULE_6  -j LOG  --log-level info --log-prefix "RULE 6 -- DENY "
    $IPTABLES -A RULE_6  -j DROP
    # 
    # Rule 7 (global)
    # 
    echo "Rule 7 (global)"
    # 
    $IPTABLES -A INPUT  -s 192.168.1.0/24   -m state --state NEW  -j ACCEPT
    $IPTABLES -A OUTPUT  -s 192.168.1.0/24   -m state --state NEW  -j ACCEPT
    $IPTABLES -A FORWARD  -s 192.168.1.0/24   -m state --state NEW  -j ACCEPT
    # 
    # Rule 8 (global)
    # 
    echo "Rule 8 (global)"
    # 
    $IPTABLES -N RULE_8
    $IPTABLES -A OUTPUT  -j RULE_8
    $IPTABLES -A INPUT  -j RULE_8
    $IPTABLES -A FORWARD  -j RULE_8
    $IPTABLES -A RULE_8  -j LOG  --log-level info --log-prefix "RULE 8 -- DENY "
    $IPTABLES -A RULE_8  -j DROP
}

ip_forward() {
    :
    echo 1 > /proc/sys/net/ipv4/ip_forward
}

reset_all() {
    :
    reset_iptables_v4
}

block_action() {
    reset_all
}

stop_action() {
    reset_all
    $IPTABLES  -P OUTPUT  ACCEPT
    $IPTABLES  -P INPUT   ACCEPT
    $IPTABLES  -P FORWARD ACCEPT
}

check_iptables() {
    IP_TABLES="$1"
    [ ! -e $IP_TABLES ] && return 151
    NF_TABLES=$(cat $IP_TABLES 2>/dev/null)
    [ -z "$NF_TABLES" ] && return 152
    return 0
}
status_action() {
    check_iptables "/proc/net/ip_tables_names"
    ret_ipv4=$?
    check_iptables "/proc/net/ip6_tables_names"
    ret_ipv6=$?
    [ $ret_ipv4 -eq 0 -o $ret_ipv6 -eq 0 ] && return 0
    [ $ret_ipv4 -eq 151 -o $ret_ipv6 -eq 151 ] && {
        echo "iptables modules are not loaded"
    }
    [ $ret_ipv4 -eq 152 -o $ret_ipv6 -eq 152 ] && {
        echo "Firewall is not configured"
    }
    exit 3
}

# See how we were called.
# For backwards compatibility missing argument is equivalent to 'start'

cmd=$1
test -z "$cmd" && {
    cmd="start"
}

case "$cmd" in
    start)
        log "Activating firewall script generated Tue Jun 26 16:28:43 2018 by root"
        check_tools
         prolog_commands 
        check_run_time_address_table_files
        
        load_modules "nat "
        configure_interfaces
        verify_interfaces
        
         reset_all 
        
        script_body
        ip_forward
        
        epilog_commands
        RETVAL=$?
        ;;

    stop)
        stop_action
        RETVAL=$?
        ;;

    status)
        status_action
        RETVAL=$?
        ;;

    block)
        block_action
        RETVAL=$?
        ;;

    reload)
        $0 stop
        $0 start
        RETVAL=$?
        ;;

    interfaces)
        configure_interfaces
        RETVAL=$?
        ;;

    test_interfaces)
        FWBDEBUG="echo"
        configure_interfaces
        RETVAL=$?
        ;;



    *)
        echo "Usage $0 [start|stop|status|block|reload|interfaces|test_interfaces]"
        ;;

esac

exit $RETVAL
