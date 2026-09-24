```fortios
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

config firewall vip
    edit "VIP_COWRIE_HONEYPOT_2222"
        set extip 192.168.40.1
        set mappedip "192.168.10.2"
        set extintf "port2.40"
        set portforward enable
        set protocol tcp
        set extport 2222
        set mappedport 2222
    next
end

config firewall policy
    edit 10
        set name "INBOUND_HONEYPOT_DECEPTION"
        set srcintf "port2.40"
        set dstintf "port2.10"
        set action accept
        set srcaddr "all"
        set dstaddr "VIP_COWRIE_HONEYPOT_2222"
        set schedule "always"
        set service "ALL"
        set logtraffic all
    next
    edit 20
        set name "OUTBOUND_HONEYPOT_WEBHOOK_TO_FGT"
        set srcintf "port2.10"
        set dstintf "port2.10"
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
        set event-type webhook
    next
end

config system automation-action
    edit "ACT_QUARANTINE_ATTACKER_IP"
        set action-type quarantine
        set quarantine-log enable
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
