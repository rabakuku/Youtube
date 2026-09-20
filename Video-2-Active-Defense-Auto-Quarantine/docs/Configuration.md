```markdown
<!-- filepath: docs/Configuration.md -->
# Application & Webhook Configuration: n8n Auto-Quarantine Pipeline

This guide details the end-to-end setup for the containerized n8n workflow engine running on Alpine Linux (`192.168.10.2:80`). It provides step-by-step instructions to configure the incoming webhook listener, process hostile source IP addresses extracted from FortiOS anomaly alerts, and invoke the FortiOS REST API to isolate attacker nodes dynamically.

---

## 1. Initial Access & User Onboarding

1. Open a browser and navigate to `http://192.168.10.2:80/`.
2. Complete the initial user registration screen:
   * **Email**: `admin@lab.local`
   * **First Name**: `SOAR`
   * **Last Name**: `Admin`
   * **Password**: Secure password matching deployment standards.
3. Skip the optional telemetry prompts to enter the canvas editor.

---

## 2. Workflow Design: Threat Detection & Remediation Engine

The automated containment pipeline comprises four discrete execution stages:


```

+---------------------+     +--------------------+     +-----------------------+     +-------------------------+
|   Webhook Trigger   | --> |  Address Validator | --> | Create Address Object | --> | Add to Quarantine Group |
| (FortiOS JSON POST) |     |  (CIDR Whitelist)  |     |  (FortiOS REST POST)  |     |   (FortiOS REST PUT)    |
+---------------------+     +--------------------+     +-----------------------+     +-------------------------+

```

### Node 1: Webhook Trigger (`Webhook-FortiOS-Anomaly`)
* **HTTP Method**: `POST`
* **Path**: `quarantine`
* **Response Mode**: `On Received`
* **Response Code**: `200`
* **Webhook URL (Production)**: `http://192.168.10.2:80/webhook/quarantine`
* **Webhook URL (Test)**: `http://192.168.10.2:80/webhook-test/quarantine`

### Node 2: Code Node (`Threat-Extraction-and-Filter`)
Extracts the source IP from incoming FortiOS event parameters and prevents auto-quarantine loops on internal subnets:
```javascript
const items = $input.all();
const returnData = [];

for (const item of items) {
  // Extract srcip from FortiOS stitch JSON payload
  const attackerIp = item.json.body?.srcip || item.json.srcip || item.json.body?.log?.srcip;

  if (!attackerIp) {
    throw new NodeError(this, "No valid srcip found in the FortiOS webhook payload.");
  }

  // Protect internal orchestrator and gateway from inadvertent containment
  const whitelist = ["192.168.10.1", "192.168.10.2", "127.0.0.1"];
  if (whitelist.includes(attackerIp)) {
    continue;
  }

  returnData.push({
    json: {
      attacker_ip: attackerIp,
      object_name: `QUAR_${attackerIp}`,
      comment: "Automated isolation via SOAR stitch trigger"
    }
  });
}

return returnData;

```

### Node 3: HTTP Request (`FortiGate-Create-Firewall-Address`)

Creates the `/32` host address object within the FortiOS firewall table.

* **Method**: `POST`
* **URL**: `https://192.168.10.1:443/api/v2/cmdb/firewall/address`
* **Authentication**: Generic Credential Type -> Header Auth
* **Header Name**: `Authorization`
* **Header Value**: `Bearer autoquarantine-sec-token-xyz123`


* **Ignore SSL Issues**: `True` (Self-signed lab certificates)
* **Send Body**: `True`
* **Body Content Type**: `JSON`
* **Specify Body**:
```json
{
  "name": "={{ $json.object_name }}",
  "type": "ipmask",
  "subnet": "={{ $json.attacker_ip }} 255.255.255.255",
  "comment": "={{ $json.comment }}"
}

```



### Node 4: HTTP Request (`FortiGate-Append-Quarantine-Group`)

Appends the new address object to the dynamic isolation group bound to the edge drop policy.

* **Method**: `PUT`
* **URL**: `https://192.168.10.1:443/api/v2/cmdb/firewall/addrgrp/GRP_ACTIVE_QUARANTINE`
* **Authentication**: Generic Credential Type -> Header Auth
* **Header Name**: `Authorization`
* **Header Value**: `Bearer autoquarantine-sec-token-xyz123`


* **Ignore SSL Issues**: `True`
* **Send Body**: `True`
* **Body Content Type**: `JSON`
* **Specify Body**:
```json
{
  "member": [
    {
      "name": "={{ $json.object_name }}"
    }
  ]
}

```



---

## 3. Workflow Import Document

Copy the raw JSON definition below and import it directly into n8n (**Workflows** -> **Import from File / Paste JSON**):

```json
{
  "name": "FortiOS-Auto-Quarantine-Pipeline",
  "nodes": [
    {
      "parameters": {
        "httpMethod": "POST",
        "path": "quarantine",
        "responseMode": "onReceived",
        "responseData": "OK",
        "options": {}
      },
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 2,
      "position": [
        0,
        0
      ],
      "id": "c7a6e7df-e9bf-4781-a83d-3aa9a4561001",
      "name": "FortiOS Anomaly Webhook",
      "webhookId": "quarantine"
    },
    {
      "parameters": {
        "jsCode": "const items = $input.all();\nconst returnData = [];\n\nfor (const item of items) {\n  const attackerIp = item.json.body?.srcip || item.json.srcip || item.json.body?.log?.srcip;\n  \n  if (!attackerIp) {\n    continue;\n  }\n  \n  const whitelist = ['192.168.10.1', '192.168.10.2', '127.0.0.1'];\n  if (whitelist.includes(attackerIp)) {\n    continue;\n  }\n  \n  returnData.push({\n    json: {\n      attacker_ip: attackerIp,\n      object_name: `QUAR_${attackerIp}`,\n      comment: 'Automated isolation via SOAR stitch trigger'\n    }\n  });\n}\n\nreturn returnData;"
      },
      "type": "n8n-nodes-base.code",
      "typeVersion": 2,
      "position": [
        220,
        0
      ],
      "id": "b6a5e7df-e9bf-4781-a83d-3aa9a4561002",
      "name": "Filter & Whitelist Check"
    },
    {
      "parameters": {
        "method": "POST",
        "url": "[https://192.168.10.1:443/api/v2/cmdb/firewall/address](https://192.168.10.1:443/api/v2/cmdb/firewall/address)",
        "sendHeaders": true,
        "headerParameters": {
          "parameters": [
            {
              "name": "Authorization",
              "value": "Bearer autoquarantine-sec-token-xyz123"
            }
          ]
        },
        "sendBody": true,
        "specifyBody": "json",
        "jsonBody": "={\n  \"name\": \"{{ $json.object_name }}\",\n  \"type\": \"ipmask\",\n  \"subnet\": \"{{ $json.attacker_ip }} 255.255.255.255\",\n  \"comment\": \"{{ $json.comment }}\"\n}",
        "options": {
          "allowUnauthorizedCerts": true
        }
      },
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [
        440,
        0
      ],
      "id": "a5a5e7df-e9bf-4781-a83d-3aa9a4561003",
      "name": "Create Host Address Object"
    },
    {
      "parameters": {
        "method": "PUT",
        "url": "[https://192.168.10.1:443/api/v2/cmdb/firewall/addrgrp/GRP_ACTIVE_QUARANTINE](https://192.168.10.1:443/api/v2/cmdb/firewall/addrgrp/GRP_ACTIVE_QUARANTINE)",
        "sendHeaders": true,
        "headerParameters": {
          "parameters": [
            {
              "name": "Authorization",
              "value": "Bearer autoquarantine-sec-token-xyz123"
            }
          ]
        },
        "sendBody": true,
        "specifyBody": "json",
        "jsonBody": "={\n  \"member\": [\n    {\n      \"name\": \"{{ $json.object_name }}\"\n    }\n  ]\n}",
        "options": {
          "allowUnauthorizedCerts": true
        }
      },
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 4.2,
      "position": [
        660,
        0
      ],
      "id": "94a5e7df-e9bf-4781-a83d-3aa9a4561004",
      "name": "Append to Quarantine Group"
    }
  ],
  "connections": {
    "FortiOS Anomaly Webhook": {
      "main": [
        [
          {
            "node": "Filter & Whitelist Check",
            "type": "main",
            "index": 0
          }
        ]
      ]
    },
    "Filter & Whitelist Check": {
      "main": [
        [
          {
            "node": "Create Host Address Object",
            "type": "main",
            "index": 0
          }
        ]
      ]
    },
    "Create Host Address Object": {
      "main": [
        [
          {
            "node": "Append to Quarantine Group",
            "type": "main",
            "index": 0
          }
        ]
      ]
    }
  },
  "active": true,
  "settings": {
    "executionOrder": "v1"
  }
}

```

---

## 4. Activation & Persistence Verification

1. In the top-right corner of the canvas, toggle the workflow from **Inactive** to **Active**.
2. Confirm persistent volume mapping on the Alpine host to prevent state loss across container restarts:
* Data volume: `n8n_enterprise_data` -> `/home/node/.n8n`
* Database storage: `n8n_enterprise_postgres` -> `/var/lib/postgresql/data`



```

---

### Step-by-Step Terminal Execution Guide

Execute the following steps on the Alpine host (`192.168.10.2`):

1. **Verify that the database and application containers are running:**
   ```sh
   docker compose -f ~/soar-stack/compose/docker-compose.yml ps

```

*Confirms both core services are operational and healthy prior to handling workflow events.*

2. **Inspect the live execution logs to monitor webhook registration:**
```sh
docker compose -f ~/soar-stack/compose/docker-compose.yml logs -f --tail=20 n8n

```


*Streams application event logs in real time to trace incoming HTTP requests and identify syntax errors during flow evaluation.*

---

### Zero-Trust Verification Blocker (Stage 4)

Execute these diagnostic tests directly from the **Kali Linux Attacker Node** (`192.168.10.3`) to validate the webhook ingestion interface before Fortinet integration.

#### 1. Test Ingress Connectivity & HTTP Status Code

Send a simulated event payload to the production webhook path:

```bash
curl -X POST http://192.168.10.2:80/webhook/quarantine \
  -H "Content-Type: application/json" \
  -d '{"srcip": "192.168.10.3", "logid": "0100022001", "msg": "Aggressive SYN Scan Detected"}' \
  -w "\nHTTP Response Code: %{http_code}\n"

```

*Verification standard:* Output must conclude with:

```text
HTTP Response Code: 200

```

#### 2. Verify Ingestion on Alpine Host

Check the n8n application logs on Node 2 (`192.168.10.2`):

```sh
docker compose -f ~/soar-stack/compose/docker-compose.yml logs --tail=25 n8n | grep -i "webhook"

```

*Verification standard:* Logs must confirm receipt of the POST event on `/webhook/quarantine` without HTTP 404 or 500 error traces.

When the webhook returns HTTP 200 and the transaction appears in the container logs, reply with:

`"I am done with Stage 4"`
