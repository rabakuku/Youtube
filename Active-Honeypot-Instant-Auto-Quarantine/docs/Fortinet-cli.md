```fortios
   config system accprofile
       edit "PROF_WEBHOOK_QUARANTINE"
           set comments "Access profile for honeypot auto-quarantine automation"
           set secfabread write
           set sysgrp read-write
           set netgrp read-write
           set loggrp read-write
           set fwgrp read-write
       next
   end

   config system api-user
       edit "api_cowrie_quarantine"
           set accprofile "PROF_WEBHOOK_QUARANTINE"
           set vdom "root"
           config trusthost
               edit 1
                   set ipv4-trusthost 192.168.10.2 255.255.255.255
               next
           end
       next
   end

execute api-user generate-key api_cowrie_quarantine

config firewall address
    edit "NET_SERVERS_VLAN10"
        set subnet 192.168.10.0 255.255.255.0
    next
    edit "NET_USERS_VLAN40"
        set subnet 192.168.40.0 255.255.255.0
    next
    edit "HOST_ALPINE_HONEYPOT"
        set subnet 192.168.10.2 255.255.255.255
    next
    edit "HOST_KALI_ATTACKER"
        set subnet 192.168.40.3 255.255.255.255
    next
end

config system interface
    edit "port2"
        set vdom "root"
        set allowaccess ping https ssh http
        set type physical
        set description "TRUNK-Internal"
        set alias "TRUNK"
    next
end

config system interface
    edit "VLAN_QC_10"
        set vdom "root"
        set ip 192.168.10.1 255.255.255.0
        set allowaccess ping https ssh http
        set alias "SERVERS"
        set device-identification enable
        set role lan
        set ip-managed-by-fortiipam disable
        set interface "port2"
        set vlanid 10
    next
end
config system interface
    edit "VLAN_QC_40"
        set vdom "root"
        set ip 192.168.40.1 255.255.255.0
        set allowaccess ping https ssh http
        set alias "USERS"
        set device-identification enable
        set role lan
        set ip-managed-by-fortiipam disable
        set interface "port2"
        set vlanid 40
    next
end

config system zone
    edit "WAN"
        set interface "port1"
    next
    edit "USERS"
        set interface "VLAN_QC_40"
    next
    edit "DMZ"
        set interface "port3"
    next
    edit "SERVERS"
        set interface "VLAN_QC_10"
    next
end

config firewall vip
    edit "VIP_COWRIE_HONEYPOT_2222"
        set extip 192.168.40.1
        set mappedip "192.168.10.2"
        set extintf "any"
        set portforward enable
        set protocol tcp
        set extport 2222
        set mappedport 2222
    next
end

config firewall policy
    edit 3
        set name "USERS TO SERVERS"
        set srcintf "USERS"
        set dstintf "SERVERS"
        set action accept
        set srcaddr "all"
        set dstaddr "VIP_COWRIE_HONEYPOT_2222"
        set schedule "always"
        set service "ALL"
        set logtraffic all
    next
end
    edit 20
        set name "OUTBOUND_HONEYPOT_WEBHOOK_TO_FGT"
        set srcintf "SERVERS"
        set dstintf "SERVERS"
        set action accept
        set srcaddr "HOST_ALPINE_HONEYPOT"
        set dstaddr "all"
        set schedule "always"
        set service "HTTPS"
        set logtraffic all
    next
end

config system automation-trigger
    edit "TRIG_COWRIE_QUARANTINE"
        set event-type incoming-webhook
    next
end

config system automation-action
    edit "ACT_QUARANTINE_ATTACKER_IP"
        set action-type quarantine
    next
end

config system automation-stitch
    edit "STITCH_COWRIE_AUTO_QUARANTINE"
        set status enable
        set trigger "TRIG_COWRIE_QUARANTINE"
        config actions
            edit 1
                set action "ACT_QUARANTINE_ATTACKER_IP"
                set required enable
            next
        end
    next
end
```
