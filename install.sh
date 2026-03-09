#!/bin/bash
# ProxmoxVE Script Monitor – install to /root/lookscript
set -e

BASE="/root/lookscript"
mkdir -p "$BASE/backend" "$BASE/frontend"
echo "→ Writing files to $BASE"

# ── docker-compose.yml ───────────────────────────────────────────────────────
cat > "$BASE/docker-compose.yml" << 'EOF'
services:
  proxmox-monitor:
    build: .
    container_name: proxmox-monitor
    ports:
      - "8099:5000"
    volumes:
      - proxmox-monitor-data:/data
    restart: unless-stopped
    environment:
      - TZ=UTC
      # Optional: set your Discord webhook URL here instead of via the web UI.
      # Only applied on first boot if no webhook is saved yet.
      # - DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN

volumes:
  proxmox-monitor-data:
EOF

# ── Dockerfile ───────────────────────────────────────────────────────────────
cat > "$BASE/Dockerfile" << 'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY backend/ ./backend/
COPY frontend/ ./frontend/
RUN mkdir -p /data
WORKDIR /app/backend
EXPOSE 5000
CMD ["python", "app.py"]
EOF

# ── backend/requirements.txt ─────────────────────────────────────────────────
cat > "$BASE/backend/requirements.txt" << 'EOF'
flask==3.0.0
flask-cors==4.0.0
requests==2.31.0
EOF

# ── backend/app.py ───────────────────────────────────────────────────────────
cat > "$BASE/backend/app.py" << 'APPEOF'
from flask import Flask, jsonify, request, send_from_directory
from flask_cors import CORS
import json
import os
import requests
import time
import threading
import logging
from datetime import datetime, timezone

app = Flask(__name__, static_folder='../frontend', static_url_path='')
CORS(app)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

DATA_FILE = '/data/state.json'
SCRAPE_URL = 'https://community-scripts.github.io/ProxmoxVE/scripts'
CHECK_INTERVAL = 3600  # 1 hour

def load_state():
    if os.path.exists(DATA_FILE):
        with open(DATA_FILE, 'r') as f:
            return json.load(f)
    return {
        'webhook_url': '',
        'known_scripts': {},
        'events': []
    }

def save_state(state):
    os.makedirs(os.path.dirname(DATA_FILE), exist_ok=True)
    with open(DATA_FILE, 'w') as f:
        json.dump(state, f, indent=2)

def fetch_scripts():
    """Fetch all scripts from the official static JSON API.

    Endpoint: https://community-scripts.github.io/ProxmoxVE/api/categories
    This is a pre-rendered Next.js route (force-static) that returns:
      [ { "name": "Category", "id": 1, "scripts": [ { slug, name,
          description, logo, date_created, type, disable, ... } ] } ]
    """
    API_URL = 'https://community-scripts.github.io/ProxmoxVE/api/categories'
    headers = {
        'User-Agent': 'Mozilla/5.0 (compatible; ProxmoxMonitor/1.0)',
        'Accept': 'application/json',
    }
    try:
        resp = requests.get(API_URL, headers=headers, timeout=30)
        resp.raise_for_status()
        categories = resp.json()

        scripts = {}
        for category in categories:
            for script in category.get('scripts', []):
                slug = (script.get('slug') or '').strip()
                if not slug or script.get('disable'):
                    continue

                date_str = script.get('date_created', '')
                if date_str and 'T' in date_str:
                    date_str = date_str.split('T')[0]

                icon = script.get('logo') or ''
                if not icon:
                    icon = f"https://cdn.jsdelivr.net/gh/selfhst/icons@main/webp/{slug}.webp"

                scripts[slug] = {
                    'id':          slug,
                    'name':        script.get('name', slug),
                    'description': script.get('description', ''),
                    'date':        date_str,
                    'icon':        icon,
                    'type':        script.get('type', ''),
                    'category':    category.get('name', ''),
                    'url':         f"https://community-scripts.github.io/ProxmoxVE/scripts?id={slug}",
                }

        logger.info(f"Fetched {len(scripts)} scripts from /api/categories")
        return scripts

    except Exception as e:
        logger.error(f"fetch_scripts error: {e}")
        return {}

def send_discord_embed(webhook_url, script):
    """Send a Discord embed for a new script."""
    try:
        name = script.get('name', 'Unknown Script')
        description = script.get('description', '')
        if len(description) > 300:
            description = description[:297] + '...'
        
        date = script.get('date', '')
        icon = script.get('icon', '')
        url = script.get('url', SCRAPE_URL)
        
        embed = {
            "title": f"🆕 New Script: {name}",
            "description": description,
            "url": url,
            "color": 0xE67E22,
            "fields": [],
            "footer": {
                "text": "ProxmoxVE Community Scripts Monitor",
                "icon_url": "https://cdn.jsdelivr.net/gh/selfhst/icons@main/webp/proxmox.webp"
            },
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
        
        if date:
            embed["fields"].append({"name": "📅 Added", "value": date, "inline": True})
        
        if icon:
            embed["thumbnail"] = {"url": icon}
        
        payload = {
            "username": "ProxmoxVE Script Monitor",
            "avatar_url": "https://cdn.jsdelivr.net/gh/selfhst/icons@main/webp/proxmox.webp",
            "embeds": [embed]
        }
        
        resp = requests.post(webhook_url, json=payload, timeout=10)
        resp.raise_for_status()
        logger.info(f"Sent Discord notification for: {name}")
        return True
    except Exception as e:
        logger.error(f"Failed to send Discord embed: {e}")
        return False

def check_for_new_scripts():
    """Main monitoring loop."""
    logger.info("Starting script monitor...")
    
    while True:
        try:
            state = load_state()
            current_scripts = fetch_scripts()
            
            if not current_scripts:
                logger.warning("No scripts fetched, skipping check")
                time.sleep(CHECK_INTERVAL)
                continue
            
            known = state.get('known_scripts', {})

            # ── First run ────────────────────────────────────────────────────
            # Sort ALL fetched scripts by date_created descending, surface the
            # 3 newest as timeline events (no Discord ping on first boot), then
            # mark everything as known so only genuinely new slugs fire later.
            if not known:
                logger.info(f"First run: {len(current_scripts)} scripts found")

                # Sort by date string descending (ISO dates sort lexicographically)
                sorted_scripts = sorted(
                    current_scripts.values(),
                    key=lambda s: s.get('date', ''),
                    reverse=True
                )
                top3 = sorted_scripts[:3]

                # Add init event at the bottom
                state['events'].append({
                    'type': 'init',
                    'message': f'Monitor started. Seeding latest 3 of {len(current_scripts)} tracked scripts.',
                    'timestamp': datetime.now(timezone.utc).isoformat()
                })

                # Insert top-3 as new_script events (newest first = index 0)
                for script in reversed(top3):
                    state['events'].insert(0, {
                        'type': 'new_script',
                        'script': script,
                        'timestamp': datetime.now(timezone.utc).isoformat(),
                        'notified': False,  # first-boot seeds don't ping Discord
                        'seeded': True      # flag so UI can show "seeded" vs truly new
                    })
                    logger.info(f"Seeded on first run: {script.get('name')} ({script.get('date')})")

                state['known_scripts'] = current_scripts
                state['events'] = state['events'][:200]
                save_state(state)

            # ── Subsequent runs ──────────────────────────────────────────────
            else:
                new_found = [s for sid, s in current_scripts.items() if sid not in known]
                # Sort new scripts oldest→newest so timeline reads chronologically
                new_found.sort(key=lambda s: s.get('date', ''))

                webhook_url = state.get('webhook_url', '')
                for script in new_found:
                    logger.info(f"New script found: {script.get('name')} ({script.get('date')})")
                    event = {
                        'type': 'new_script',
                        'script': script,
                        'timestamp': datetime.now(timezone.utc).isoformat(),
                        'notified': False
                    }
                    if webhook_url:
                        event['notified'] = send_discord_embed(webhook_url, script)
                    state['events'].insert(0, event)

                state['events'].insert(0, {
                    'type': 'check',
                    'message': (
                        f'Check complete. Found {len(new_found)} new script(s).'
                        if new_found else
                        f'Check complete. No new scripts. Total tracked: {len(current_scripts)}'
                    ),
                    'timestamp': datetime.now(timezone.utc).isoformat()
                })
                state['events'] = state['events'][:200]
                state['known_scripts'].update(current_scripts)
                if new_found:
                    logger.info(f"Found {len(new_found)} new script(s)")
                save_state(state)
        
        except Exception as e:
            logger.error(f"Monitor error: {e}")
        
        time.sleep(CHECK_INTERVAL)

# --- API Routes ---

@app.route('/')
def index():
    return send_from_directory('../frontend', 'index.html')

@app.route('/api/events', methods=['GET'])
def get_events():
    state = load_state()
    return jsonify({
        'events': state.get('events', []),
        'total_tracked': len(state.get('known_scripts', {}))
    })

@app.route('/api/webhook', methods=['GET'])
def get_webhook():
    state = load_state()
    url = state.get('webhook_url', '')
    # Mask the URL for security
    masked = ''
    if url:
        parts = url.split('/')
        if len(parts) > 2:
            masked = '/'.join(parts[:5]) + '/*****/***'
    return jsonify({'webhook_url': masked, 'configured': bool(url)})

@app.route('/api/webhook', methods=['POST'])
def set_webhook():
    data = request.get_json()
    if not data or 'webhook_url' not in data:
        return jsonify({'error': 'webhook_url required'}), 400
    
    url = data['webhook_url'].strip()
    if url and 'discord.com/api/webhooks/' not in url:
        return jsonify({'error': 'Invalid Discord webhook URL'}), 400
    
    state = load_state()
    state['webhook_url'] = url
    save_state(state)
    
    return jsonify({'success': True, 'message': 'Webhook saved'})

@app.route('/api/webhook/test', methods=['POST'])
def test_webhook():
    state = load_state()
    webhook_url = state.get('webhook_url', '')
    
    if not webhook_url:
        return jsonify({'error': 'No webhook configured'}), 400
    
    test_script = {
        'name': 'Test Script LXC',
        'description': 'This is a test notification from your ProxmoxVE Script Monitor. If you see this, your webhook is working correctly!',
        'date': datetime.now().strftime('%Y-%m-%d'),
        'icon': 'https://cdn.jsdelivr.net/gh/selfhst/icons@main/webp/proxmox.webp',
        'url': SCRAPE_URL
    }
    
    success = send_discord_embed(webhook_url, test_script)
    if success:
        return jsonify({'success': True, 'message': 'Test notification sent!'})
    else:
        return jsonify({'error': 'Failed to send test notification'}), 500

@app.route('/api/check', methods=['POST'])
def trigger_check():
    """Manually trigger a check."""
    def run_check():
        try:
            state = load_state()
            current_scripts = fetch_scripts()

            if not current_scripts:
                return

            known = state.get('known_scripts', {})
            new_found = [s for sid, s in current_scripts.items() if sid not in known]
            new_found.sort(key=lambda s: s.get('date', ''))

            webhook_url = state.get('webhook_url', '')
            for script in new_found:
                logger.info(f"Manual check — new: {script.get('name')} ({script.get('date')})")
                event = {
                    'type': 'new_script',
                    'script': script,
                    'timestamp': datetime.now(timezone.utc).isoformat(),
                    'notified': False
                }
                if webhook_url:
                    event['notified'] = send_discord_embed(webhook_url, script)
                state['events'].insert(0, event)

            state['events'].insert(0, {
                'type': 'check',
                'message': (
                    f'Manual check complete. Found {len(new_found)} new script(s).'
                    if new_found else
                    f'Manual check complete. No new scripts. Total tracked: {len(current_scripts)}'
                ),
                'timestamp': datetime.now(timezone.utc).isoformat()
            })
            state['events'] = state['events'][:200]
            state['known_scripts'].update(current_scripts)
            save_state(state)
        except Exception as e:
            logger.error(f"Manual check error: {e}")
    
    thread = threading.Thread(target=run_check)
    thread.daemon = True
    thread.start()
    
    return jsonify({'success': True, 'message': 'Check triggered'})

@app.route('/api/reset', methods=['POST'])
def reset_state():
    """Wipe known_scripts and events, keep webhook. Re-runs first-boot seed with Discord notifications."""
    def run_reset():
        try:
            state = load_state()
            webhook_url = state.get('webhook_url', '')

            # Clear everything except the webhook
            state['known_scripts'] = {}
            state['events'] = []
            save_state(state)
            logger.info("State reset triggered from UI")

            # Now re-run the first-boot logic — this time it WILL ping Discord
            current_scripts = fetch_scripts()
            if not current_scripts:
                logger.warning("Reset: no scripts fetched")
                return

            sorted_scripts = sorted(
                current_scripts.values(),
                key=lambda s: s.get('date', ''),
                reverse=True
            )
            top3 = sorted_scripts[:3]

            state['events'].append({
                'type': 'init',
                'message': f'State reset. Re-seeding latest 3 of {len(current_scripts)} scripts.',
                'timestamp': datetime.now(timezone.utc).isoformat()
            })

            for script in reversed(top3):
                logger.info(f"Reset seed: {script.get('name')} ({script.get('date')})")
                event = {
                    'type': 'new_script',
                    'script': script,
                    'timestamp': datetime.now(timezone.utc).isoformat(),
                    'notified': False,
                    'seeded': True
                }
                if webhook_url:
                    event['notified'] = send_discord_embed(webhook_url, script)
                state['events'].insert(0, event)

            state['known_scripts'] = current_scripts
            state['events'] = state['events'][:200]
            save_state(state)
            logger.info("Reset complete")
        except Exception as e:
            logger.error(f"Reset error: {e}")

    thread = threading.Thread(target=run_reset)
    thread.daemon = True
    thread.start()
    return jsonify({'success': True, 'message': 'Reset triggered'})


@app.route('/api/stats', methods=['GET'])
def get_stats():
    state = load_state()
    events = state.get('events', [])
    new_script_events = [e for e in events if e.get('type') == 'new_script']
    
    return jsonify({
        'total_tracked': len(state.get('known_scripts', {})),
        'total_new_found': len(new_script_events),
        'webhook_configured': bool(state.get('webhook_url', '')),
        'last_check': events[0].get('timestamp') if events else None
    })

if __name__ == '__main__':
    # If DISCORD_WEBHOOK_URL env var is set and no webhook saved yet, use it
    env_webhook = os.environ.get('DISCORD_WEBHOOK_URL', '').strip()
    if env_webhook:
        state = load_state()
        if not state.get('webhook_url'):
            state['webhook_url'] = env_webhook
            save_state(state)
            logger.info("Webhook URL loaded from DISCORD_WEBHOOK_URL env var")
        else:
            logger.info("Webhook already set in state, DISCORD_WEBHOOK_URL env var ignored")

    # Start monitor in background thread
    monitor_thread = threading.Thread(target=check_for_new_scripts)
    monitor_thread.daemon = True
    monitor_thread.start()

    app.run(host='0.0.0.0', port=5000, debug=False)

APPEOF

# ── frontend/index.html ───────────────────────────────────────────────────────
cat > "$BASE/frontend/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>ProxmoxVE Script Monitor</title>
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link href="https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&family=DM+Sans:wght@300;400;500;600&display=swap" rel="stylesheet" />
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      --bg:       #0d0f14;
      --surface:  #141720;
      --card:     #1a1e2a;
      --border:   #252b3b;
      --accent:   #e06c1f;
      --accent2:  #f59e0b;
      --green:    #22c55e;
      --red:      #ef4444;
      --blue:     #3b82f6;
      --text:     #e8eaf0;
      --muted:    #6b7280;
      --mono:     'Space Mono', monospace;
      --sans:     'DM Sans', sans-serif;
    }

    html, body {
      background: var(--bg);
      color: var(--text);
      font-family: var(--sans);
      min-height: 100vh;
    }

    /* Subtle grid bg */
    body::before {
      content: '';
      position: fixed;
      inset: 0;
      background-image:
        linear-gradient(rgba(224,108,31,.03) 1px, transparent 1px),
        linear-gradient(90deg, rgba(224,108,31,.03) 1px, transparent 1px);
      background-size: 40px 40px;
      pointer-events: none;
      z-index: 0;
    }

    .app { position: relative; z-index: 1; max-width: 1100px; margin: 0 auto; padding: 0 20px 60px; }

    /* ── Header ── */
    header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 28px 0 24px;
      border-bottom: 1px solid var(--border);
      margin-bottom: 32px;
      gap: 16px;
      flex-wrap: wrap;
    }

    .logo {
      display: flex;
      align-items: center;
      gap: 14px;
    }

    .logo-icon {
      width: 44px;
      height: 44px;
      background: linear-gradient(135deg, var(--accent), var(--accent2));
      border-radius: 10px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 22px;
    }

    .logo-text h1 {
      font-family: var(--mono);
      font-size: 1.1rem;
      font-weight: 700;
      letter-spacing: -0.5px;
      line-height: 1.2;
    }

    .logo-text p {
      font-size: 0.75rem;
      color: var(--muted);
      font-family: var(--mono);
      margin-top: 2px;
    }

    .header-actions { display: flex; gap: 10px; align-items: center; }

    /* ── Stat Pills ── */
    .stats-bar {
      display: flex;
      gap: 12px;
      margin-bottom: 28px;
      flex-wrap: wrap;
    }

    .stat-pill {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 10px 18px;
      display: flex;
      align-items: center;
      gap: 10px;
      flex: 1;
      min-width: 140px;
    }

    .stat-pill .stat-icon {
      width: 32px;
      height: 32px;
      border-radius: 8px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 16px;
      flex-shrink: 0;
    }

    .stat-pill .stat-icon.orange { background: rgba(224,108,31,.15); }
    .stat-pill .stat-icon.green  { background: rgba(34,197,94,.15); }
    .stat-pill .stat-icon.blue   { background: rgba(59,130,246,.15); }

    .stat-pill .stat-val {
      font-family: var(--mono);
      font-size: 1.4rem;
      font-weight: 700;
      line-height: 1;
    }

    .stat-pill .stat-lbl {
      font-size: 0.72rem;
      color: var(--muted);
      text-transform: uppercase;
      letter-spacing: .08em;
      margin-top: 2px;
    }

    /* ── Layout ── */
    .layout {
      display: grid;
      grid-template-columns: 1fr 340px;
      gap: 20px;
      align-items: start;
    }

    @media (max-width: 800px) {
      .layout { grid-template-columns: 1fr; }
    }

    /* ── Panel ── */
    .panel {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 12px;
      overflow: hidden;
    }

    .panel-header {
      padding: 16px 20px;
      border-bottom: 1px solid var(--border);
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
    }

    .panel-title {
      font-family: var(--mono);
      font-size: 0.8rem;
      letter-spacing: .12em;
      text-transform: uppercase;
      color: var(--muted);
    }

    /* ── Buttons ── */
    .btn {
      font-family: var(--sans);
      font-size: 0.82rem;
      font-weight: 500;
      border: none;
      border-radius: 7px;
      padding: 8px 16px;
      cursor: pointer;
      transition: all .15s ease;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      white-space: nowrap;
    }

    .btn-primary {
      background: var(--accent);
      color: #fff;
    }
    .btn-primary:hover { background: #c95e17; transform: translateY(-1px); }

    .btn-ghost {
      background: transparent;
      color: var(--muted);
      border: 1px solid var(--border);
    }
    .btn-ghost:hover { color: var(--text); border-color: var(--muted); background: var(--surface); }

    .btn-success {
      background: rgba(34,197,94,.15);
      color: var(--green);
      border: 1px solid rgba(34,197,94,.25);
    }
    .btn-success:hover { background: rgba(34,197,94,.25); }

    .btn-danger {
      background: rgba(239,68,68,.15);
      color: var(--red);
      border: 1px solid rgba(239,68,68,.25);
    }
    .btn-danger:hover { background: rgba(239,68,68,.25); }

    .btn:disabled { opacity: .4; cursor: not-allowed; transform: none !important; }

    /* ── Timeline ── */
    .timeline { padding: 8px 0; }

    .tl-empty {
      padding: 40px 24px;
      text-align: center;
      color: var(--muted);
      font-size: 0.88rem;
    }

    .tl-empty svg { margin-bottom: 12px; opacity: .4; }

    .tl-item {
      display: flex;
      gap: 0;
      padding: 0 20px;
      position: relative;
      animation: fadeIn .35s ease both;
    }

    @keyframes fadeIn {
      from { opacity: 0; transform: translateY(8px); }
      to   { opacity: 1; transform: translateY(0); }
    }

    .tl-line-col {
      display: flex;
      flex-direction: column;
      align-items: center;
      width: 36px;
      flex-shrink: 0;
      padding-top: 18px;
    }

    .tl-dot {
      width: 10px;
      height: 10px;
      border-radius: 50%;
      flex-shrink: 0;
      position: relative;
      z-index: 1;
    }

    .tl-dot.new-script { background: var(--accent); box-shadow: 0 0 8px rgba(224,108,31,.5); }
    .tl-dot.check      { background: var(--border); }
    .tl-dot.init       { background: var(--blue); }

    .tl-connector {
      width: 2px;
      flex: 1;
      min-height: 12px;
      background: var(--border);
      margin: 4px 0;
    }

    .tl-content {
      flex: 1;
      padding: 14px 0 14px 12px;
    }

    /* Script card inside timeline */
    .script-card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 14px;
      display: flex;
      gap: 12px;
      align-items: flex-start;
      transition: border-color .2s;
    }

    .script-card:hover { border-color: var(--accent); }

    .script-card a { text-decoration: none; color: inherit; }

    .script-icon {
      width: 40px;
      height: 40px;
      border-radius: 8px;
      background: var(--card);
      object-fit: contain;
      padding: 4px;
      flex-shrink: 0;
    }

    .script-icon-fallback {
      width: 40px;
      height: 40px;
      border-radius: 8px;
      background: var(--card);
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 18px;
      flex-shrink: 0;
    }

    .script-info { flex: 1; min-width: 0; }

    .script-name {
      font-weight: 600;
      font-size: 0.9rem;
      margin-bottom: 4px;
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
    }

    .badge {
      font-family: var(--mono);
      font-size: 0.65rem;
      padding: 2px 7px;
      border-radius: 4px;
      text-transform: uppercase;
      letter-spacing: .08em;
    }

    .badge-new    { background: rgba(224,108,31,.18); color: var(--accent); border: 1px solid rgba(224,108,31,.3); }
    .badge-notified { background: rgba(34,197,94,.12); color: var(--green); border: 1px solid rgba(34,197,94,.25); }
    .badge-failed { background: rgba(239,68,68,.12); color: var(--red); border: 1px solid rgba(239,68,68,.25); }
    .badge-seeded { background: rgba(59,130,246,.12); color: var(--blue); border: 1px solid rgba(59,130,246,.25); }

    .script-desc {
      font-size: 0.8rem;
      color: var(--muted);
      line-height: 1.5;
      display: -webkit-box;
      -webkit-line-clamp: 2;
      -webkit-box-orient: vertical;
      overflow: hidden;
    }

    .script-meta {
      display: flex;
      gap: 12px;
      margin-top: 8px;
      font-size: 0.73rem;
      color: var(--muted);
      font-family: var(--mono);
      flex-wrap: wrap;
    }

    .script-meta span { display: flex; align-items: center; gap: 4px; }

    /* System events (check / init) */
    .sys-event {
      font-size: 0.78rem;
      color: var(--muted);
      padding: 10px 0;
      font-family: var(--mono);
      display: flex;
      align-items: center;
      gap: 8px;
    }

    /* ── Sidebar ── */
    .sidebar { display: flex; flex-direction: column; gap: 16px; }

    /* Webhook card */
    .webhook-status {
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 0.8rem;
      color: var(--muted);
      margin-bottom: 14px;
    }

    .status-dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      flex-shrink: 0;
    }

    .status-dot.on  { background: var(--green); box-shadow: 0 0 6px rgba(34,197,94,.5); }
    .status-dot.off { background: var(--muted); }

    .input-group { margin-bottom: 12px; }
    .input-group label { display: block; font-size: 0.75rem; color: var(--muted); margin-bottom: 6px; font-family: var(--mono); text-transform: uppercase; letter-spacing: .08em; }

    .input-wrap { position: relative; }

    .input-wrap input {
      width: 100%;
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 10px 14px;
      color: var(--text);
      font-size: 0.82rem;
      font-family: var(--mono);
      outline: none;
      transition: border-color .2s;
    }

    .input-wrap input:focus { border-color: var(--accent); }
    .input-wrap input::placeholder { color: var(--muted); }

    .input-actions { display: flex; gap: 8px; margin-top: 10px; }
    .input-actions .btn { flex: 1; justify-content: center; }

    .msg {
      font-size: 0.78rem;
      padding: 8px 12px;
      border-radius: 6px;
      margin-top: 10px;
      display: none;
    }
    .msg.success { background: rgba(34,197,94,.1); color: var(--green); border: 1px solid rgba(34,197,94,.2); display: block; }
    .msg.error   { background: rgba(239,68,68,.1);  color: var(--red);   border: 1px solid rgba(239,68,68,.2);  display: block; }

    /* Recent scripts list */
    .recent-list { padding: 0; }
    .recent-item {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 11px 20px;
      border-bottom: 1px solid var(--border);
      font-size: 0.82rem;
      transition: background .15s;
    }
    .recent-item:last-child { border-bottom: none; }
    .recent-item:hover { background: var(--surface); }
    .recent-item img, .recent-item .ri-fallback {
      width: 28px; height: 28px;
      border-radius: 6px;
      background: var(--surface);
      object-fit: contain;
      padding: 3px;
      flex-shrink: 0;
      display: flex; align-items: center; justify-content: center;
      font-size: 14px;
    }
    .recent-item .ri-name { flex: 1; font-weight: 500; color: var(--text); }
    .recent-item .ri-date { font-family: var(--mono); font-size: 0.7rem; color: var(--muted); }

    /* ── Spinner ── */
    @keyframes spin { to { transform: rotate(360deg); } }
    .spinner {
      width: 14px; height: 14px;
      border: 2px solid rgba(255,255,255,.2);
      border-top-color: #fff;
      border-radius: 50%;
      animation: spin .6s linear infinite;
      display: inline-block;
    }

    /* ── Pulse for live badge ── */
    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50%       { opacity: .4; }
    }
    .live-badge {
      font-family: var(--mono);
      font-size: 0.65rem;
      color: var(--green);
      display: flex;
      align-items: center;
      gap: 5px;
    }
    .live-badge::before {
      content: '';
      width: 6px; height: 6px;
      background: var(--green);
      border-radius: 50%;
      animation: pulse 2s ease-in-out infinite;
    }

    /* Scrollbar */
    ::-webkit-scrollbar { width: 6px; }
    ::-webkit-scrollbar-track { background: var(--bg); }
    ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
    ::-webkit-scrollbar-thumb:hover { background: var(--muted); }

    /* Toast */
    #toast {
      position: fixed;
      bottom: 24px;
      right: 24px;
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 12px 20px;
      font-size: 0.85rem;
      box-shadow: 0 8px 32px rgba(0,0,0,.4);
      transform: translateY(80px);
      opacity: 0;
      transition: all .3s ease;
      z-index: 999;
      max-width: 320px;
    }
    #toast.show { transform: translateY(0); opacity: 1; }
    #toast.t-success { border-color: rgba(34,197,94,.4); color: var(--green); }
    #toast.t-error   { border-color: rgba(239,68,68,.4);  color: var(--red); }
    #toast.t-info    { border-color: rgba(224,108,31,.4); color: var(--accent); }

    /* Refresh animation */
    @keyframes rotate { to { transform: rotate(360deg); } }
    .rotating { animation: rotate .6s linear; }
  </style>
</head>
<body>
<div class="app">

  <!-- Header -->
  <header>
    <div class="logo">
      <div class="logo-icon">⚡</div>
      <div class="logo-text">
        <h1>ProxmoxVE Monitor</h1>
        <p>community-scripts tracker</p>
      </div>
    </div>
    <div class="header-actions">
      <span class="live-badge">LIVE</span>
      <button class="btn btn-ghost" id="refreshBtn" onclick="refreshAll()">
        <svg id="refreshIcon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/></svg>
        Refresh
      </button>
      <button class="btn btn-primary" id="checkBtn" onclick="triggerCheck()">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg>
        Check Now
      </button>
    </div>
  </header>

  <!-- Stats -->
  <div class="stats-bar">
    <div class="stat-pill">
      <div class="stat-icon orange">📦</div>
      <div>
        <div class="stat-val" id="statTotal">—</div>
        <div class="stat-lbl">Scripts Tracked</div>
      </div>
    </div>
    <div class="stat-pill">
      <div class="stat-icon green">🆕</div>
      <div>
        <div class="stat-val" id="statNew">—</div>
        <div class="stat-lbl">New Found</div>
      </div>
    </div>
    <div class="stat-pill">
      <div class="stat-icon blue">🕒</div>
      <div>
        <div class="stat-val" id="statLastCheck">—</div>
        <div class="stat-lbl">Last Check</div>
      </div>
    </div>
  </div>

  <!-- Main layout -->
  <div class="layout">

    <!-- Timeline -->
    <div>
      <div class="panel">
        <div class="panel-header">
          <span class="panel-title">Event Timeline</span>
          <span id="eventCount" style="font-size:.75rem;color:var(--muted);font-family:var(--mono)"></span>
        </div>
        <div class="timeline" id="timeline">
          <div class="tl-empty">
            <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>
            <p>Loading events…</p>
          </div>
        </div>
      </div>
    </div>

    <!-- Sidebar -->
    <div class="sidebar">

      <!-- Webhook Config -->
      <div class="panel">
        <div class="panel-header">
          <span class="panel-title">Discord Webhook</span>
          <div class="webhook-status">
            <div class="status-dot" id="webhookDot"></div>
            <span id="webhookStatusText">Not configured</span>
          </div>
        </div>
        <div style="padding: 16px;">
          <div class="input-group">
            <label>Webhook URL</label>
            <div class="input-wrap">
              <input type="password" id="webhookInput" placeholder="https://discord.com/api/webhooks/…" />
            </div>
          </div>
          <div class="input-actions">
            <button class="btn btn-primary" onclick="saveWebhook()">
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"/><polyline points="17 21 17 13 7 13 7 21"/><polyline points="7 3 7 8 15 8"/></svg>
              Save
            </button>
            <button class="btn btn-ghost" id="testBtn" onclick="testWebhook()">
              <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/></svg>
              Test
            </button>
          </div>
          <div class="msg" id="webhookMsg"></div>
        </div>
      </div>

      <!-- Recent new scripts -->
      <div class="panel">
        <div class="panel-header">
          <span class="panel-title">Recent New Scripts</span>
        </div>
        <div class="recent-list" id="recentList">
          <div style="padding:20px;text-align:center;color:var(--muted);font-size:.82rem;">No new scripts detected yet.</div>
        </div>
      </div>

      <!-- Info -->
      <div class="panel">
        <div class="panel-header"><span class="panel-title">About</span></div>
        <div style="padding:16px;font-size:.8rem;color:var(--muted);line-height:1.7;">
          <p>Monitors <a href="https://community-scripts.github.io/ProxmoxVE/scripts" target="_blank" style="color:var(--accent);text-decoration:none;">community-scripts.github.io</a> for new Proxmox scripts.</p>
          <br>
          <p>⏱ Auto-checks every <strong style="color:var(--text)">60 minutes</strong>.</p>
          <p>🔔 Sends Discord embeds for each new script.</p>
          <p>📋 Keeps the last 200 events in history.</p>
        </div>
      </div>

      <!-- Force Reset -->
      <div class="panel" style="border-color: rgba(239,68,68,.2);">
        <div class="panel-header" style="border-color: rgba(239,68,68,.2);">
          <span class="panel-title" style="color:var(--red);">Danger Zone</span>
        </div>
        <div style="padding:16px;">
          <p style="font-size:.78rem;color:var(--muted);margin-bottom:12px;line-height:1.6;">Clears all known scripts and event history, then re-seeds the 3 newest scripts — <strong style="color:var(--text)">including Discord notifications</strong>. Useful for testing.</p>
          <button class="btn btn-danger" id="resetBtn" onclick="forceReset()" style="width:100%;justify-content:center;">
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/></svg>
            Force Reset & Re-seed
          </button>
          <div class="msg" id="resetMsg"></div>
        </div>
      </div>

    </div>
  </div>
</div>

<!-- Toast -->
<div id="toast"></div>

<script>
  const API = '';

  function toast(msg, type = 'info') {
    const t = document.getElementById('toast');
    t.textContent = msg;
    t.className = `show t-${type}`;
    clearTimeout(t._timer);
    t._timer = setTimeout(() => t.classList.remove('show'), 3500);
  }

  function timeAgo(iso) {
    if (!iso) return '—';
    const diff = (Date.now() - new Date(iso)) / 1000;
    if (diff < 60)   return 'just now';
    if (diff < 3600) return `${Math.floor(diff/60)}m ago`;
    if (diff < 86400) return `${Math.floor(diff/3600)}h ago`;
    return `${Math.floor(diff/86400)}d ago`;
  }

  function formatDate(iso) {
    if (!iso) return '';
    try {
      const d = new Date(iso);
      return d.toLocaleString(undefined, { month:'short', day:'numeric', hour:'2-digit', minute:'2-digit' });
    } catch { return iso; }
  }

  function imgEl(src, alt) {
    const img = document.createElement('img');
    img.src = src;
    img.alt = alt || '';
    img.className = 'script-icon';
    img.onerror = function() {
      const fb = document.createElement('div');
      fb.className = 'script-icon-fallback';
      fb.textContent = '📦';
      this.replaceWith(fb);
    };
    return img;
  }

  function renderTimeline(events) {
    const container = document.getElementById('timeline');
    document.getElementById('eventCount').textContent = `${events.length} event${events.length !== 1 ? 's' : ''}`;

    if (!events.length) {
      container.innerHTML = `<div class="tl-empty">
        <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>
        <p>No events yet. Try checking now!</p></div>`;
      return;
    }

    container.innerHTML = '';
    events.forEach((ev, i) => {
      const item = document.createElement('div');
      item.className = 'tl-item';
      item.style.animationDelay = `${i * 0.04}s`;

      const lineCol = document.createElement('div');
      lineCol.className = 'tl-line-col';

      const dot = document.createElement('div');
      dot.className = `tl-dot ${ev.type || 'check'}`;

      const connector = document.createElement('div');
      connector.className = 'tl-connector';

      lineCol.appendChild(dot);
      if (i < events.length - 1) lineCol.appendChild(connector);

      const content = document.createElement('div');
      content.className = 'tl-content';

      if (ev.type === 'new_script' && ev.script) {
        const s = ev.script;
        const card = document.createElement('div');
        card.className = 'script-card';

        // Icon
        if (s.icon) {
          card.appendChild(imgEl(s.icon, s.name));
        } else {
          const fb = document.createElement('div');
          fb.className = 'script-icon-fallback';
          fb.textContent = '📦';
          card.appendChild(fb);
        }

        const info = document.createElement('div');
        info.className = 'script-info';

        const nameRow = document.createElement('div');
        nameRow.className = 'script-name';
        const nameLink = document.createElement('a');
        nameLink.href = s.url || '#';
        nameLink.target = '_blank';
        nameLink.textContent = s.name || 'Unknown Script';
        nameRow.appendChild(nameLink);

        const badgeNew = document.createElement('span');
        badgeNew.className = ev.seeded ? 'badge badge-seeded' : 'badge badge-new';
        badgeNew.textContent = ev.seeded ? 'SEEDED' : 'NEW';
        nameRow.appendChild(badgeNew);

        if (ev.seeded) {
          // seeded on first boot — no Discord ping, just informational
        } else if (ev.notified) {
          const badgeNotif = document.createElement('span');
          badgeNotif.className = 'badge badge-notified';
          badgeNotif.textContent = '✓ Sent';
          nameRow.appendChild(badgeNotif);
        } else if (ev.notified === false && !ev.seeded) {
          // only show failed if it was a real attempt (webhook configured)
        }

        const desc = document.createElement('div');
        desc.className = 'script-desc';
        desc.textContent = s.description || '';

        const meta = document.createElement('div');
        meta.className = 'script-meta';
        if (s.date) meta.innerHTML += `<span>📅 ${s.date}</span>`;
        meta.innerHTML += `<span>🕒 ${timeAgo(ev.timestamp)}</span>`;

        info.appendChild(nameRow);
        info.appendChild(desc);
        info.appendChild(meta);
        card.appendChild(info);
        content.appendChild(card);

      } else {
        const sysEl = document.createElement('div');
        sysEl.className = 'sys-event';
        const icon = ev.type === 'init' ? '🚀' : '🔍';
        sysEl.innerHTML = `<span>${icon}</span><span>${ev.message || 'System event'}</span><span style="margin-left:auto;opacity:.5">${timeAgo(ev.timestamp)}</span>`;
        content.appendChild(sysEl);
      }

      item.appendChild(lineCol);
      item.appendChild(content);
      container.appendChild(item);
    });
  }

  function renderRecent(events) {
    const newScripts = events.filter(e => e.type === 'new_script' && e.script).slice(0, 8);
    const container = document.getElementById('recentList');
    if (!newScripts.length) {
      container.innerHTML = '<div style="padding:20px;text-align:center;color:var(--muted);font-size:.82rem;">No new scripts detected yet.</div>';
      return;
    }
    container.innerHTML = '';
    newScripts.forEach(ev => {
      const s = ev.script;
      const item = document.createElement('div');
      item.className = 'recent-item';

      if (s.icon) {
        const img = document.createElement('img');
        img.src = s.icon;
        img.alt = s.name;
        img.onerror = function() {
          const fb = document.createElement('div');
          fb.className = 'ri-fallback';
          fb.textContent = '📦';
          this.replaceWith(fb);
        };
        item.appendChild(img);
      } else {
        const fb = document.createElement('div');
        fb.className = 'ri-fallback';
        fb.textContent = '📦';
        item.appendChild(fb);
      }

      const name = document.createElement('span');
      name.className = 'ri-name';
      name.textContent = s.name || '—';

      const date = document.createElement('span');
      date.className = 'ri-date';
      date.textContent = s.date || timeAgo(ev.timestamp);

      item.appendChild(name);
      item.appendChild(date);
      container.appendChild(item);
    });
  }

  async function loadEvents() {
    try {
      const r = await fetch(`${API}/api/events`);
      const d = await r.json();
      renderTimeline(d.events || []);
      renderRecent(d.events || []);
    } catch(e) { console.error('loadEvents error', e); }
  }

  async function loadStats() {
    try {
      const r = await fetch(`${API}/api/stats`);
      const d = await r.json();
      document.getElementById('statTotal').textContent = d.total_tracked ?? '—';
      document.getElementById('statNew').textContent = d.total_new_found ?? '—';
      document.getElementById('statLastCheck').textContent = d.last_check ? timeAgo(d.last_check) : '—';

      const dot = document.getElementById('webhookDot');
      const statusText = document.getElementById('webhookStatusText');
      if (d.webhook_configured) {
        dot.className = 'status-dot on';
        statusText.textContent = 'Connected';
        statusText.style.color = 'var(--green)';
      } else {
        dot.className = 'status-dot off';
        statusText.textContent = 'Not configured';
        statusText.style.color = '';
      }
    } catch(e) { console.error('loadStats error', e); }
  }

  async function refreshAll() {
    const icon = document.getElementById('refreshIcon');
    icon.classList.add('rotating');
    await Promise.all([loadEvents(), loadStats()]);
    setTimeout(() => icon.classList.remove('rotating'), 600);
    toast('Refreshed', 'info');
  }

  async function triggerCheck() {
    const btn = document.getElementById('checkBtn');
    btn.disabled = true;
    btn.innerHTML = '<span class="spinner"></span> Checking…';
    try {
      const r = await fetch(`${API}/api/check`, { method: 'POST' });
      const d = await r.json();
      toast('Check triggered! Refreshing in 5s…', 'info');
      setTimeout(refreshAll, 5000);
    } catch(e) {
      toast('Failed to trigger check', 'error');
    } finally {
      setTimeout(() => {
        btn.disabled = false;
        btn.innerHTML = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></svg> Check Now';
      }, 2000);
    }
  }

  async function forceReset() {
    const btn = document.getElementById('resetBtn');
    const msg = document.getElementById('resetMsg');
    if (!confirm('This will clear all state and re-seed the 3 newest scripts, sending Discord notifications if a webhook is configured. Continue?')) return;
    btn.disabled = true;
    btn.innerHTML = '<span class="spinner"></span> Resetting…';
    try {
      const r = await fetch(`${API}/api/reset`, { method: 'POST' });
      const d = await r.json();
      if (d.success) {
        msg.className = 'msg success';
        msg.textContent = '✓ Reset triggered! Refreshing in 5s…';
        toast('Reset triggered!', 'success');
        setTimeout(refreshAll, 5000);
      } else {
        msg.className = 'msg error';
        msg.textContent = d.error || 'Reset failed';
        toast('Reset failed', 'error');
      }
    } catch(e) {
      msg.className = 'msg error';
      msg.textContent = 'Connection error';
      toast('Connection error', 'error');
    } finally {
      setTimeout(() => {
        btn.disabled = false;
        btn.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/></svg> Force Reset & Re-seed';
        msg.className = 'msg';
      }, 6000);
    }
  }

  async function saveWebhook() {
    const url = document.getElementById('webhookInput').value.trim();
    const msg = document.getElementById('webhookMsg');
    try {
      const r = await fetch(`${API}/api/webhook`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ webhook_url: url })
      });
      const d = await r.json();
      if (d.success) {
        msg.className = 'msg success';
        msg.textContent = '✓ Webhook saved successfully';
        toast('Webhook saved!', 'success');
        loadStats();
      } else {
        msg.className = 'msg error';
        msg.textContent = d.error || 'Failed to save';
      }
    } catch(e) {
      msg.className = 'msg error';
      msg.textContent = 'Connection error';
    }
    setTimeout(() => msg.className = 'msg', 4000);
  }

  async function testWebhook() {
    const btn = document.getElementById('testBtn');
    btn.disabled = true;
    btn.innerHTML = '<span class="spinner"></span> Sending…';
    const msg = document.getElementById('webhookMsg');
    try {
      const r = await fetch(`${API}/api/webhook/test`, { method: 'POST' });
      const d = await r.json();
      if (d.success) {
        msg.className = 'msg success';
        msg.textContent = '✓ Test sent! Check your Discord channel.';
        toast('Test notification sent!', 'success');
      } else {
        msg.className = 'msg error';
        msg.textContent = d.error || 'Test failed';
        toast('Test failed', 'error');
      }
    } catch(e) {
      msg.className = 'msg error';
      msg.textContent = 'Connection error';
    } finally {
      setTimeout(() => {
        btn.disabled = false;
        btn.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/></svg> Test';
        msg.className = 'msg';
      }, 4000);
    }
  }

  // Init
  (async () => {
    await Promise.all([loadEvents(), loadStats()]);
    // Auto-refresh every 2 minutes
    setInterval(refreshAll, 120000);
    // Update time-ago strings every 30s
    setInterval(() => {
      document.getElementById('statLastCheck') && loadStats();
    }, 30000);
  })();
</script>
</body>
</html>

HTMLEOF

echo ""
echo "✅ All files written to $BASE"
echo ""
echo "Next steps:"
echo "  cd $BASE"
echo "  docker compose up -d --build"
echo "  Then open: http://\$(hostname -I | awk '{print \$1}'):8099"
