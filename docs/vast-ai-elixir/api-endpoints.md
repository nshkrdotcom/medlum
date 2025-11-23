# Vast.ai API Endpoints Reference

Base URL: `https://console.vast.ai/api/v0`

## Instance Management

### Search Offers
```
GET /bundles/
```
Search for available GPU offers.

Query params: See `search-query-syntax.md`

Response: List of offer objects with GPU specs, pricing, availability.

### Show Instances
```
GET /instances/
```
List user's current instances.

### Show Instance
```
GET /instances/{id}/
```
Get details of a specific instance.

### Create Instance
```
PUT /instances/{id}/
```
Create instance from offer ID.

Request body:
```json
{
  "client_id": "me",
  "image": "pytorch/pytorch",
  "disk": 40,
  "label": "my-instance",
  "onstart": "#!/bin/bash\necho hello",
  "runtype": "ssh",
  "image_login": "-u user -p pass registry.io",
  "env": {
    "TZ": "UTC",
    "MY_VAR": "value"
  },
  "python_utf8": false,
  "lang_utf8": false,
  "use_jupyter_lab": false,
  "jupyter_dir": null,
  "create_from": null,
  "force": false
}
```

Response:
```json
{
  "success": true,
  "new_contract": 7835610
}
```

### Update Instance
```
PUT /instances/{id}/
```
Update instance configuration.

### Destroy Instance
```
DELETE /instances/{id}/
```
Permanently delete instance and data.

### Start Instance
```
PUT /instances/{id}/
```
Start a stopped instance.

Request body:
```json
{
  "state": "running"
}
```

### Stop Instance
```
PUT /instances/{id}/
```
Stop a running instance.

Request body:
```json
{
  "state": "stopped"
}
```

### Reboot Instance
```
POST /instances/reboot/{id}/
```
Stop and start instance without losing GPU priority.

### Recycle Instance
```
POST /instances/recycle/{id}/
```
Destroy and recreate instance.

### Label Instance
```
PUT /instances/{id}/
```
Set instance label.

Request body:
```json
{
  "label": "my-label"
}
```

### Get Instance Logs
```
GET /instances/request_logs/{id}
```
Retrieve instance logs.

Query params:
- `tail`: Number of lines (default 1000)

### Execute Command
```
POST /instances/command/{id}/
```
Execute constrained command on instance.

Request body:
```json
{
  "command": "ls -la"
}
```

Available commands: `ls`, `rm`, `du`

### Change Bid Price
```
PUT /instances/bid_price/{id}/
```
Change bid for spot instance.

Request body:
```json
{
  "price": 0.15
}
```

### Prepay Instance
```
POST /instances/prepay/{id}/
```
Add prepaid credits to reserved instance.

Request body:
```json
{
  "amount": 100.0
}
```

### Instance Balance
```
GET /instances/balance/{id}/
```
Get prepaid balance for instance.

## SSH Key Management

### List SSH Keys
```
GET /ssh/
```

### Create SSH Key
```
POST /ssh/
```
Request body:
```json
{
  "ssh_key": "ssh-rsa AAAAB3..."
}
```

### Update SSH Key
```
PUT /ssh/{id}/
```

### Delete SSH Key
```
DELETE /ssh/{id}/
```

### Attach SSH to Instance
```
POST /instances/{id}/ssh/
```
Request body:
```json
{
  "ssh_key": "ssh-rsa AAAAB3..."
}
```

### Detach SSH from Instance
```
DELETE /instances/{id}/ssh/{ssh_key_id}/
```

## API Key Management

### List API Keys
```
GET /auth/apikeys/
```

### Show API Key
```
GET /auth/apikeys/{id}/
```

### Create API Key
```
POST /auth/apikeys/
```
Request body:
```json
{
  "name": "my-key",
  "permissions": {
    "api": {
      "misc": {},
      "instance_read": {},
      "instance_write": {}
    }
  }
}
```

### Delete API Key
```
DELETE /auth/apikeys/{id}/
```

## User & Account

### Show Current User
```
GET /users/current/
```

### Show User
```
GET /users/
```

### Show IP Addresses
```
GET /users/{user_id}/ipaddrs/
```

### Show Subaccounts
```
GET /subaccounts/
```

### Create Subaccount
```
POST /subaccounts/
```
Request body:
```json
{
  "email": "user@example.com",
  "username": "newuser",
  "password": "securepass",
  "type": "client"
}
```

### Transfer Credit
```
POST /commands/transfer_credit/
```
Request body:
```json
{
  "recipient": "user@example.com",
  "amount": 50.0
}
```

## Billing

### Show Invoices
```
GET /users/{user_id}/invoices/
```
Query params:
- `start_date`: Start date
- `end_date`: End date
- `only_charges`: Show charges only
- `only_credits`: Show credits only

### Search Invoices
```
GET /invoices
```

### Show Earnings (Hosts)
```
GET /users/{user_id}/machine-earnings/
```

## Data Transfer

### Copy Files
```
POST /commands/copy_direct/
```
Request body:
```json
{
  "src": "6003036:/workspace/",
  "dst": "6003038:/workspace/"
}
```

### Cloud Copy
```
POST /commands/rclone/
```
Copy to/from cloud providers.

### Cancel Copy
```
DELETE /commands/copy_direct/
```

## Templates

### List Templates
```
GET /template/
```

### Create Template
```
POST /template/
```

### Update Template
```
PUT /template/{id}/
```

### Delete Template
```
DELETE /template/{id}/
```

## Autoscalers (Serverless)

### List Autoscalers
```
GET /workergroups/
```

### Show Autoscaler
```
GET /workergroups/{id}/
```

### Create Autoscaler
```
POST /workergroups/
```
Request body:
```json
{
  "min_load": 100,
  "target_util": 0.9,
  "cold_mult": 2.5,
  "gpu_ram": 32.0,
  "search_params": "gpu_ram>=23 num_gpus=2 gpu_name=RTX_4090",
  "launch_args": "--image pytorch/pytorch --disk 64",
  "endpoint_name": "my-endpoint"
}
```

### Update Autoscaler
```
PUT /workergroups/{id}/
```

### Delete Autoscaler
```
DELETE /workergroups/{id}/
```

## Endpoints

### List Endpoints
```
GET /endptjobs/
```

### Show Endpoint
```
GET /endptjobs/{id}/
```

### Create Endpoint
```
POST /endptjobs/
```

### Update Endpoint
```
PUT /endptjobs/{id}/
```

### Delete Endpoint
```
DELETE /endptjobs/{id}/
```

## Team Management

### Show Team Members
```
GET /team/members/
```

### Invite Team Member
```
POST /team/invite/
```
Request body:
```json
{
  "email": "member@example.com",
  "role": "admin"
}
```

### Remove Team Member
```
DELETE /team/members/{id}
```

### List Team Roles
```
GET /team/roles/
```

### Show Team Role
```
GET /team/roles/{name}
```

### Create Team Role
```
POST /team/roles/
```

### Update Team Role
```
PUT /team/roles/{id}/
```

### Delete Team Role
```
DELETE /team/roles/{id}/
```

### Create Team
```
POST /team/
```

### Destroy Team
```
DELETE /team/
```

## Host Operations

### Show Machines
```
GET /machines/
```

### List Machine
```
POST /machines/create_asks/
```
List machine for rent.

Request body:
```json
{
  "machine_id": 12345,
  "price_gpu": 0.50,
  "price_disk": 0.15,
  "price_inetu": 0.02,
  "price_inetd": 0.02,
  "discount_rate": 0.4,
  "min_chunk": 1,
  "end_date": 1700000000
}
```

### Unlist Machine
```
DELETE /asks/{id}/
```

### Set Minimum Bid
```
PUT /machines/{machine_id}/minbid/
```

### Set Default Job
```
PUT /machines/{machine_id}/defjob/
```

### Remove Default Job
```
DELETE /machines/{machine_id}/defjob/
```

### Schedule Maintenance
```
POST /machines/{machine_id}/dnotify
```

### Cancel Maintenance
```
DELETE /machines/{machine_id}/cancel_maint/
```

### Cleanup Machine
```
POST /machines/{machine_id}/cleanup/
```

### Machine Reports
```
GET /machines/{machine_id}/reports/
```

## Volumes

### List Volumes
```
GET /volumes/
```

### Search Volumes
```
GET /volumes/search/
```

### Create Volume
```
POST /volumes/
```

### Delete Volume
```
DELETE /volumes/{id}/
```

### Unlist Volume
```
POST /volumes/unlist/
```

## Network Volumes

### Add Network Disk
```
POST /network_disk/
```

### List Network Volume
```
POST /network_volume/
```

### Search Network Volumes
```
GET /network_volumes/search/
```

### Unlist Network Volume
```
POST /network_volumes/unlist/
```

## Benchmarks

### Search Benchmarks
```
GET /benchmarks/
```

## Secrets

### Manage Secrets
```
GET/POST/DELETE /secrets/
```

## Cloud Integrations

### Show Connections
```
GET /users/cloud_integrations/
```
