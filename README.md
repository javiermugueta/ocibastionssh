# ocibastionssh

[See also here](https://javiermugueta.wordpress.com/2025/09/21/utility-to-access-a-machine-in-oracle-cloud-through-bastion-service-utilidad-para-acceder-a-un-maquina-en-oracle-cloud-a-traves-de-bastion-service/)

This is a simple script that opens an SSH session with an OCI machine. The script uses 7 parameters:

Usage: ./ocibastion.sh <SESSION_PREFIX> <REGION> <BASTION_NAME> <BASTION_IP> <BASTION_PORT> <REMOTE_HOST> <REMOTE_HOST_PRIVATE_KEY>

## Requirements

You need to have a Bastion Service already created, and remember its name (the script will search for its OCID)
You need the private key of the opc user for the remote machine

## Advanced Features

There’s no need to use the OCID, you just provide the name of the bastion
The script remembers the bastion’s OCID so it don’t have to search for it again on each run
If a bastion session already exists, it won’t create a new one, it will reuse the existing session
Two windows open: one with the bastion session, and another with an SSH session to the remote host you want to access

## Setup

git clone https://github.com/javiermugueta/ocibastionssh.git
cd ocibastionssh
chmod 700 ocibastion.sh

Note: It has only been tested on MacOS.

I hope this is helpful!