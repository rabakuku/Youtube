# FortiOS 7.4 Security Fabric Deception & Quarantine Configuration (GUI Guide)

Follow these sequential steps in the FortiGate Web GUI to establish firewall objects, the Virtual IP (VIP), security policies, and the quarantine Automation Stitch.

---

### Step 1: Create Firewall Address Objects
1. Navigate to **Policy & Objects > Addresses**.
2. Click **Create New > Address**.
3. Create the honeypot host object:
   * **Name:** `HOST_ALPINE_HONEYPOT`
   * **Type:** `Subnet`
   * **IP/Netmask:** `192.168.10.2/32`
   * **Interface:** `port2.10`
   * Click **OK**.
4. Create the attacker subnet object:
   * **Name:** `NET_USERS_VLAN40`
   * **Type:** `Subnet`
   * **IP/Netmask:** `192.168.40.0/24`
   * **Interface:** `port2.40`
   * Click **OK**.

---

### Step 2: Configure Virtual IP (Port Forwarding VIP)
1. Navigate to **Policy & Objects > Virtual IPs**.
2. Click **Create New > Virtual IP**.
3. Fill in the parameters:
   * **Name:** `VIP_COWRIE_HONEYPOT_2222`
   * **Interface:** `port2.40`
   * **External IP Address/Range:** `192.168.40.1`
   * **Mapped IP Address/Range:** `192.168.10.2`
   * Toggle **Port Forwarding** to **ON**.
   * **Protocol:** `TCP`
   * **External Service Port:** `2222`
   * **Map to IPv4 Port:** `2222`
4. Click **OK**.

---

### Step 3: Create Firewall Policies
1. Navigate to **Policy & Objects > Firewall Policy**.
2. Click **Create New** to allow incoming honeypot probes:
   * **Name:** `INBOUND_HONEYPOT_DECEPTION`
   * **Incoming Interface:** `port2.40`
   * **Outgoing Interface:** `port2.10`
   * **Source:** `all`
   * **Destination:** `VIP_COWRIE_HONEYPOT_2222`
   * **Schedule:** `always`
   * **Service:** `ALL`
   * **Action:** `ACCEPT`
   * **NAT:** Disabled (preserve genuine attacker source IP)
   * **Log Allowed Traffic:** `All Sessions`
   * Click **OK**.

---

### Step 4: Configure Fabric Automation Trigger & Action
1. Navigate to **Security Fabric > Automation**.
2. Select the **Trigger** tab and click **Create New**:
   * **Name:** `TRIG_COWRIE_QUARANTINE`
   * **Trigger Type:** `Incoming Webhook`
   * Click **OK**.
3. Select the **Action** tab and click **Create New**:
   * **Name:** `ACT_QUARANTINE_ATTACKER_IP`
   * **Action Type:** `Quarantine / Ban IP`
   * Click **OK**.

---

### Step 5: Assemble the Automation Stitch
1. Navigate to **Security Fabric > Automation > Stitch**.
2. Click **Create New**:
   * **Name:** `STITCH_COWRIE_AUTO_QUARANTINE`
   * **Status:** `Enabled`
   * Click **Add Trigger** and select `TRIG_COWRIE_QUARANTINE`.
   * Click **Add Action** and select `ACT_QUARANTINE_ATTACKER_IP`.
3. Click **OK** to commit the active quarantine loop.
