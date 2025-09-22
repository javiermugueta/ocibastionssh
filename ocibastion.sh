#!/bin/bash

# Usage: ./ocibastion.sh <SESSION_PREFIX> <REGION> <BASTION_NAME> <BASTION_IP> <BASTION_PORT> <REMOTE_HOST> <REMOTE_HOST_PRIVATE_KEY>
if [ "$#" -ne 7 ]; then
  echo "Usage: $0 <SESSION_PREFIX> <REGION> <BASTION_NAME> <BASTION_IP> <BASTION_PORT> <REMOTE_HOST> <REMOTE_HOST_PRIVATE_KEY>"
  exit 1
fi

SESSION_PREFIX="$1"
REGION="$2"
BASTION_NAME="$3"
BASTION_IP="$4"
BASTION_PORT="$5"
REMOTE_HOST="$6"
REMOTE_HOST_PRIVATE_KEY="$7"
DEST_USER="opc"

CACHE_FILE="$HOME/.ocibastion_bastion_cache_${BASTION_NAME}"
SESSION_CACHE="$HOME/.ocibastion_session_cache"

echo "Getting tenancy OCID..."
TENANCY_OCID=$(oci iam availability-domain list --all | jq -r '.data[0]."compartment-id"')
if [ -z "$TENANCY_OCID" ] || [[ "$TENANCY_OCID" != ocid1.tenancy* ]]; then
  echo "ERROR: Could not determine tenancy OCID."
  exit 1
fi

# Bastion OCID discovery (with cache)
FOUND_BASTION_OCID=""
if [ -f "$CACHE_FILE" ]; then
  FOUND_BASTION_OCID=$(grep "^$REGION|$BASTION_NAME|" "$CACHE_FILE" | head -n1 | cut -d'|' -f3)
fi

if [ -z "$FOUND_BASTION_OCID" ]; then
  echo "Listing all active compartments (progress: one dot per compartment):"
  COMPARTMENT_LIST=$(oci iam compartment list \
    --compartment-id "$TENANCY_OCID" \
    --compartment-id-in-subtree true \
    --access-level ANY \
    --all \
    --output json | jq -r '.data[] | "\(.id) \(.name)"')

  while read -r COMPARTMENT_LINE; do
    COMP_OCID=$(echo "$COMPARTMENT_LINE" | awk '{print $1}')
    echo -n "." >&2
    BASTION_ID=$(oci bastion bastion list --region "$REGION" --compartment-id "$COMP_OCID" --all --output json \
      | jq -r --arg BASTION_NAME "$BASTION_NAME" '.data[] | select(.name==$BASTION_NAME) | .id' | head -n1)
    if [ -n "$BASTION_ID" ]; then
      echo "" >&2
      echo "Found bastion $BASTION_NAME in compartment $COMP_OCID"
      FOUND_BASTION_OCID="$BASTION_ID"
      echo "$REGION|$BASTION_NAME|$FOUND_BASTION_OCID" >> "$CACHE_FILE"
      break
    fi
  done <<< "$COMPARTMENT_LIST"
fi

if [ -z "$FOUND_BASTION_OCID" ]; then
  echo "" >&2
  echo "ERROR: Bastion '$BASTION_NAME' not found in any compartment!"
  exit 1
fi

if [ "${#BASTION_PORT}" -eq 4 ]; then
  LOCAL_PORT="5${BASTION_PORT}"
else
  LOCAL_PORT="55${BASTION_PORT}"
fi

echo "Checking for existing reusable Bastion sessions..."
EXISTING_SESSION_ID=$(oci bastion session list \
  --bastion-id "$FOUND_BASTION_OCID" \
  --region "$REGION" \
  --all \
  --output json | jq -r \
    --arg ip "$BASTION_IP" --argjson port "$BASTION_PORT" '
    .data[] |
    select(
      .["target-resource-details"]["target-resource-private-ip-address"] == $ip and
      .["target-resource-details"]["target-resource-port"] == $port and
      (.["lifecycle-state"] == "ACTIVE" or .["lifecycle-state"] == "SUCCEEDED")
    ) | .id' | head -n1)

generate_and_create_session() {
  TMP_PREFIX=$(mktemp -u /tmp/oci_bastion_XXXXXXXX)
  BASTION_PRIVATE_KEY="${TMP_PREFIX}"
  BASTION_PUBLIC_KEY="${TMP_PREFIX}.pub"
  echo "Generating temporary SSH key for bastion session (${BASTION_PRIVATE_KEY})..."
  ssh-keygen -q -t rsa -b 2048 -N "" -f "$BASTION_PRIVATE_KEY"
  if [ $? -ne 0 ]; then
    echo "Error: could not generate temporary SSH key."
    exit 1
  fi
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  DISPLAY_NAME="${SESSION_PREFIX}-${TIMESTAMP}"
  echo "Creating new Bastion session (180 min TTL) with display name: $DISPLAY_NAME"
  SESSION_ID=$(oci bastion session create \
    --region "$REGION" \
    --bastion-id "$FOUND_BASTION_OCID" \
    --display-name "$DISPLAY_NAME" \
    --target-resource-details '{
      "sessionType": "PORT_FORWARDING",
      "targetResourcePort": '"$BASTION_PORT"',
      "targetResourcePrivateIpAddress": "'"$BASTION_IP"'"
    }' \
    --session-ttl-in-seconds 10800 \
    --ssh-public-key-file "$BASTION_PUBLIC_KEY" \
    --query "data.id" \
    --raw-output)
  if [ -z "$SESSION_ID" ]; then
    echo "Error: Could not get bastion session ID."
    rm -f "$BASTION_PRIVATE_KEY" "$BASTION_PUBLIC_KEY"
    exit 2
  fi
  echo "$SESSION_ID|$BASTION_PRIVATE_KEY" >> "$SESSION_CACHE"
  echo "Waiting for Bastion session to be ready (SUCCEEDED state)..."
  oci bastion session get --region "$REGION" --session-id "$SESSION_ID" --wait-for-state SUCCEEDED >/dev/null
}

if [ -n "$EXISTING_SESSION_ID" ]; then
  if [ -f "$SESSION_CACHE" ]; then
    BASTION_PRIVATE_KEY=$(grep "^$EXISTING_SESSION_ID|" "$SESSION_CACHE" | head -n1 | cut -d'|' -f2)
  else
    BASTION_PRIVATE_KEY=""
  fi
  if [ -f "$BASTION_PRIVATE_KEY" ]; then
    SESSION_ID="$EXISTING_SESSION_ID"
    echo "Reusing existing Bastion session: $SESSION_ID"
  else
    echo "WARNING: Private key for existing session not found. Creating a new Bastion session..."
    if [ -f "$SESSION_CACHE" ]; then
      grep -v "^$EXISTING_SESSION_ID|" "$SESSION_CACHE" > "${SESSION_CACHE}.tmp" && mv "${SESSION_CACHE}.tmp" "$SESSION_CACHE"
    fi
    generate_and_create_session
  fi
else
  generate_and_create_session
fi

echo "Retrieving the SSH command published by Bastion..."
SSH_CMD=""
for i in {1..5}; do
  SSH_CMD=$(oci bastion session get --region "$REGION" --session-id "$SESSION_ID" \
             --query "data.\"ssh-metadata\".command" --raw-output)
  if [ -n "$SSH_CMD" ]; then
    break
  fi
  echo "The session is not ready yet. Waiting 5 seconds..."
  sleep 5
done

if [ -z "$SSH_CMD" ]; then
  echo "Error: Could not retrieve SSH command. Check the session in OCI."
  rm -f "$BASTION_PRIVATE_KEY" "$BASTION_PUBLIC_KEY"
  exit 3
fi

#FORWARD_CMD=$(echo "$SSH_CMD" | sed "s|<localPort>|$LOCAL_PORT|; s|-i [^ ]*|-i $BASTION_PRIVATE_KEY|")
FORWARD_CMD=$(echo "$SSH_CMD" | sed "s|<localPort>|$LOCAL_PORT|; s|-i [^ ]*|-i $BASTION_PRIVATE_KEY|")" -o ServerAliveInterval=30 -o ServerAliveCountMax=360"
echo
echo "Run the following command in a dedicated terminal for SSH port forwarding (must remain open):"
echo "$FORWARD_CMD"
echo
echo "Waiting 8 seconds for Bastion infrastructure readiness..."
sleep 8

PROXY_CMD="ssh -i $REMOTE_HOST_PRIVATE_KEY -p $LOCAL_PORT -W %h:%p $DEST_USER@127.0.0.1"
FINAL_CMD="ssh -i $REMOTE_HOST_PRIVATE_KEY -o \"ProxyCommand=$PROXY_CMD\" $DEST_USER@$REMOTE_HOST"
echo "To connect to your remote host through Bastion, use:"
echo "$FINAL_CMD"
echo

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
  if command -v gnome-terminal &> /dev/null; then
    gnome-terminal -- bash -c "$FORWARD_CMD"
    sleep 4
    gnome-terminal -- bash -c "$FINAL_CMD; exec bash"
  else
    echo "$FORWARD_CMD"
    echo "$FINAL_CMD"
  fi
elif [[ "$OSTYPE" == "darwin"* ]]; then
  FORWARD_CMD_ESC=$(echo "$FORWARD_CMD" | sed 's/"/\\"/g')
  FINAL_CMD_ESC=$(echo "$FINAL_CMD" | sed 's/"/\\"/g')
  osascript <<END
tell application "Terminal"
    activate
    do script "$FORWARD_CMD_ESC"
    delay 4
    do script "$FINAL_CMD_ESC"
end tell
END
else
  echo "$FORWARD_CMD"
  echo "$FINAL_CMD"
fi

echo "Done. Bastion forwarding and connection setup completed."