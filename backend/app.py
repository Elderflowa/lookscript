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
            "title": f"🟢 {name}",
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
            webhook_url = state.get('webhook_url', '')

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
                    logger.info(f"Seeded on first run: {script.get('name')} ({script.get('date')})")
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

            # ── Subsequent runs ──────────────────────────────────────────────
            else:
                new_found = [s for sid, s in current_scripts.items() if sid not in known]
                # Sort new scripts oldest→newest so timeline reads chronologically
                new_found.sort(key=lambda s: s.get('date', ''))

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

