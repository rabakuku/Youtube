

---

### Step-by-Step Terminal Execution Guide

Execute these steps on Node 2 (`192.168.10.2`) as `soaradmin` or `root`:

1. **Create the target scripts directory and copy files:**
```sh
mkdir -p ~/soar-stack/scripts
cd ~/soar-stack/scripts

```


*Creates the script repository path and navigates into it.*
2. **Save scripts and assign execution permissions:**
Paste the two script deliverables above into `scripts/setup.sh` and `scripts/rollback.sh`, then grant executable permissions:
```sh
chmod +x ~/soar-stack/scripts/setup.sh ~/soar-stack/scripts/rollback.sh

```


*Enables direct shell execution for deployment and teardown operations.*

---

### Zero-Trust Verification Blocker (Stage 6)

Execute these checks on Node 2 (`192.168.10.2`) before triggering the gate:

#### 1. Bash Syntax Validation

Verify both scripts compile without interpreter syntax errors:

```sh
bash -n ~/soar-stack/scripts/setup.sh
bash -n ~/soar-stack/scripts/rollback.sh

```

*Verification standard:* Both commands must execute silently and exit with status code `0` (check with `echo $?`).

#### 2. Verify File Permissions

```sh
ls -la ~/soar-stack/scripts/

```

*Verification standard:* Output must show `-rwxr-xr-x` for both `setup.sh` and `rollback.sh`.

When both syntax validations and file permission checks succeed, reply with:

`"I am done with Stage 6"`
