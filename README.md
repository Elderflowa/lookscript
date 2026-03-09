<img
  src="https://raw.githubusercontent.com/Elderflowa/lookscript/refs/heads/main/lookscript.png"
  alt="Honey Icon"
  width="56"
  height="56"
/>

# lookscript
[![Docker Image Version (latest semver)](https://img.shields.io/docker/v/elderflowa/lookscript?label=lookscript%3Alatest)](https://hub.docker.com/r/elderflowa/lookscript)

**honey-dynamic** is a simple python app that monitors [Proxmox Helper Scripts](https://community-scripts.github.io/ProxmoxVE/scripts) and shows it in an event log.
It has webhook integration, which enables getting messages on for example Discord.

**Full discretion**:
This was coded with the use of Claude (AI).

## Screenshot
| Web Interface                                                                                  |
| ---------------------------------------------------------------------------------------------- |
| <img src="https://raw.githubusercontent.com/Elderflowa/lookscript/refs/heads/main/example.png" alt="Configuration" /> |
---
## Using pre-built image
Use this docker run command.
Clone this repository:
```
docker run -d \
  --name lookscript \
  -p 8099:5000 \
  -v lookscript-data:/data \
  -e DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN \
  --restart unless-stopped \
  elderflowa/lookscript
```
## Build from source
### Clone
First clone this repository.
```
git clone https://github.com/elderflowa/lookscript
cd lookscript
```
### Customize (Optional)
Take a look at the `docker-compose.yml`.
| Variable           | Default Value                                                                 | Description                                      |
|--------------------|------------------------------------------------------------------------------|--------------------------------------------------|
| `DISCORD_WEBHOOK_URL` | `https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN` | Webhook URL for sending notifications.   |

Then run it with `docker compose up -d --build`.

## License
`lookscript` is licensed under the **GNU General Public License v3.0**.  
See [LICENSE](./LICENSE) for full details.
