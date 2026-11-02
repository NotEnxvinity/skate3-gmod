"""The setup window, drawn by the player's browser instead of Tk.

Why: the Tk that setup could use on Linux (the portable Python's) is built
without Xft, so it draws bitmap X fonts and flat grey widgets, and when the
desktop's X fonts changed (a SteamOS update) the window turned ugly. A page
carries its own fonts (setup_fonts.py) and its own theme, so it looks the same
on every machine whatever the system theme or fonts are.

A tiny server on 127.0.0.1 (random port, secret in the address, only that host
name accepted) serves the page and a few calls: list folders for the Browse
dialogs, start the install, report its log. Nothing leaves the machine."""
from pathlib import Path
import base64, http.server, json, os, secrets, shutil, socketserver, subprocess, sys, threading, time, urllib.parse, webbrowser

import setup_fonts

IDLE_QUIT = 90         # seconds without the page asking anything (tab closed) before exiting
FIRST_LOAD_QUIT = 180  # seconds to wait for the page to be opened at all

PAGE = r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>__TITLE__</title>
<style>
@font-face{font-family:"S3GM Jost";font-weight:400;src:url(data:font/woff2;base64,__JOST400__) format("woff2")}
@font-face{font-family:"S3GM Jost";font-weight:700;src:url(data:font/woff2;base64,__JOST700__) format("woff2")}
:root{color-scheme:dark;--bg:#0a0e15;--panel:#111824;--panel2:#18212f;--line:#25324a;--text:#eceef2;--dim:#9aa1ae;--accent:#1c84f0;--accent2:#4aa3ff;--ok:#4fd18b;--bad:#ff5d6c}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--text);font:400 17px/1.45 "S3GM Jost",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
body{min-height:100vh;background:radial-gradient(1200px 500px at 85% -10%,#0f2c52 0,transparent 60%),var(--bg)}
main{max-width:820px;margin:0 auto;padding:28px 20px 40px}
h1{margin:0;font-weight:700;font-size:46px;letter-spacing:.04em;line-height:1}
h1 span{color:var(--accent2)}
.ver{font-family:"S3GM Jost",system-ui,sans-serif;font-weight:400;display:inline-block;margin-left:12px;padding:2px 10px;border:1px solid var(--line);border-radius:99px;color:var(--dim);font-size:15px;letter-spacing:.03em;vertical-align:middle}
.intro{color:var(--dim);margin:12px 0 22px;max-width:62ch}
label.cap{display:block;margin:16px 0 6px;font-weight:700;letter-spacing:.02em}
label.cap small{display:block;font-weight:400;color:var(--dim);font-size:14.5px}
.row{display:flex;gap:8px}
input[type=text]{flex:1;min-width:0;background:var(--panel);color:var(--text);border:1px solid var(--line);border-radius:8px;padding:10px 12px;font:400 15px/1.3 ui-monospace,"DejaVu Sans Mono",Menlo,Consolas,monospace}
input[type=text]:focus{outline:2px solid var(--accent);outline-offset:-1px}
button{font:700 16px/1 "S3GM Jost",system-ui,sans-serif;letter-spacing:.03em;border-radius:8px;border:1px solid var(--line);background:var(--panel2);color:var(--text);padding:10px 16px;cursor:pointer}
button:hover:not(:disabled){border-color:var(--dim)}
button:disabled{opacity:.45;cursor:default}
button.go{background:var(--accent);border-color:var(--accent);color:#fff;font-size:19px;padding:13px 34px}
button.go:hover:not(:disabled){background:var(--accent2);border-color:var(--accent2)}
.check{display:flex;gap:12px;align-items:flex-start;margin:20px 0 4px;cursor:pointer;color:var(--text)}
.check input{position:absolute;opacity:0}
.box{flex:none;width:22px;height:22px;margin-top:2px;border-radius:6px;border:2px solid var(--dim);display:grid;place-items:center}
.check input:checked+.box{background:var(--accent);border-color:var(--accent)}
.check input:checked+.box::after{content:"";width:6px;height:11px;border:solid #fff;border-width:0 3px 3px 0;transform:rotate(45deg) translate(-1px,-1px)}
.check input:focus-visible+.box{outline:2px solid var(--accent);outline-offset:2px}
.check small{display:block;color:var(--dim);font-size:14.5px}
.act{margin:18px 0 14px;display:flex;align-items:center;gap:16px}
#log{background:#070a10;border:1px solid var(--line);border-radius:8px;height:250px;overflow:auto;padding:10px 12px;margin:0;font:400 13px/1.45 ui-monospace,"DejaVu Sans Mono",Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-word;color:#c9ced8}
#log .err{color:var(--bad)}
.bar{height:8px;margin-top:12px;background:var(--panel);border:1px solid var(--line);border-radius:99px;overflow:hidden;position:relative}
.bar i{position:absolute;inset:0 auto 0 0;width:0;background:linear-gradient(90deg,var(--accent),var(--accent2));border-radius:99px}
.bar.run i{width:32%;animation:slide 1.3s ease-in-out infinite alternate}
.bar.done i{width:100%}
.bar.fail i{width:100%;background:var(--bad)}
@keyframes slide{from{left:0}to{left:68%}}
.note{margin:16px 0 0;padding:14px 16px;border-radius:10px;border:1px solid var(--line);background:var(--panel);white-space:pre-wrap}
.note.ok{border-color:#245c41;background:#0f2019}.note.warn{border-color:#6b5217;background:#221b0c}.note.bad{border-color:#6d2630;background:#241014}
.note b{display:block;font-size:19px;margin-bottom:4px}
.note.ok b{color:var(--ok)}.note.bad b{color:var(--bad)}.note.warn b{color:#f0c14b}
.note button{display:block;margin-top:14px}
#modal{position:fixed;inset:0;background:rgba(0,0,0,.66);display:none;place-items:center;padding:16px;z-index:9}
#modal.open{display:grid}
.dlg{width:min(680px,100%);max-height:calc(100vh - 32px);display:flex;flex-direction:column;background:var(--panel);border:1px solid var(--line);border-radius:12px;box-shadow:0 20px 60px rgba(0,0,0,.6)}
.dlg h2{margin:0;padding:16px 18px 6px;font-size:22px}
.dlg .path{display:flex;gap:8px;padding:6px 18px 10px}
.list{overflow:auto;margin:0 18px;border:1px solid var(--line);border-radius:8px;background:var(--bg);min-height:220px;flex:1}
.item{display:flex;align-items:center;gap:10px;padding:8px 12px;cursor:pointer;border-bottom:1px solid #142031;font-size:16px;word-break:break-all}
.item:hover{background:var(--panel2)}
.item.sel{background:#12335c}
.item .ic{flex:none;width:18px;height:14px;border-radius:3px;background:var(--dim)}
.item.dir .ic{background:var(--accent);clip-path:polygon(0 15%,38% 15%,48% 0,100% 0,100% 100%,0 100%)}
.item.file .ic{width:14px;height:18px;background:var(--dim)}
.item.hint{color:var(--dim);cursor:default}
.dlg .foot{display:flex;justify-content:flex-end;gap:10px;padding:14px 18px}
@media(max-width:560px){h1{font-size:36px}.act{flex-direction:column;align-items:stretch}}
</style></head><body><main>
<h1>S3<span>GM</span><span class="ver" id="ver"></span></h1>
<p class="intro">Check your Garry's Mod folder and your own Skate 3 (Xbox 360) disc image below, then press Install. Setup installs the S3GM addon and skate engine and converts what it needs from your disc. The first time takes a few minutes.</p>

<label class="cap" for="gmod">Your garrysmod folder <small>lowercase, the one INSIDE GarrysMod: .../steamapps/common/GarrysMod/garrysmod</small></label>
<div class="row"><input type="text" id="gmod" spellcheck="false" autocomplete="off"><button id="bgmod" type="button">Browse...</button></div>

<label class="cap" for="disc">Your Skate 3 disc image <small>the .iso, or default.xex in an extracted copy</small></label>
<div class="row"><input type="text" id="disc" spellcheck="false" autocomplete="off"><button id="bdisc" type="button">Browse...</button></div>

<label class="check"><input type="checkbox" id="engine" checked><span class="box"></span>
<span>Skate 3's own sound engine (beta): also prepare its sounds from your disc.<small>Needs a few GB of free space and a few more minutes.</small></span></label>

<div class="act"><button class="go" id="go" type="button">Install</button></div>
<pre id="log" aria-live="polite"></pre>
<div class="bar" id="bar"><i></i></div>
<div id="result"></div>
</main>

<div id="modal"><div class="dlg" role="dialog" aria-modal="true">
<h2 id="mtitle">Pick</h2>
<div class="path"><button id="mup" type="button">Up</button><input type="text" id="mpath" spellcheck="false"><button id="mgo" type="button">Go</button></div>
<div class="list" id="mlist"></div>
<div class="foot"><button id="mcancel" type="button">Cancel</button><button class="go" id="mok" type="button" style="font-size:16px;padding:10px 22px">Use this</button></div>
</div></div>

<script>
const T=location.pathname.split('/')[1], API=p=>'/'+T+'/api/'+p;
const $=id=>document.getElementById(id);
async function call(p,body){const r=await fetch(API(p),body?{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)}:{});return r.json()}
let seen=0,running=false,finished=false;
function setLogLines(lines){const log=$('log');const stick=log.scrollTop+log.clientHeight>=log.scrollHeight-24;
  for(const l of lines){const d=document.createElement('div');d.textContent=l.text;if(l.err)d.className='err';log.appendChild(d)}
  if(stick)log.scrollTop=log.scrollHeight}
function note(kind,title,text,extra){const r=$('result');r.innerHTML='';const n=document.createElement('div');n.className='note '+kind;
  const b=document.createElement('b');b.textContent=title;n.appendChild(b);n.appendChild(document.createTextNode(text||''));
  if(extra){const x=document.createElement('button');x.textContent=extra.label;x.onclick=extra.fn;n.appendChild(x)}r.appendChild(n);n.scrollIntoView({block:'nearest'})}
function setRunning(on){running=on;$('go').disabled=on;$('bar').className='bar'+(on?' run':'')}
async function poll(){
  try{const s=await call('status?since='+seen);setLogLines(s.lines);seen=s.n;
    if(s.state==='running'&&!running)setRunning(true);
    if((s.state==='done'||s.state==='error')&&!finished){finished=true;setRunning(false);
      $('bar').className='bar '+(s.state==='done'?'done':'fail');
      const close={label:'Close setup',fn:()=>{call('quit',{});document.title='You can close this tab.';document.body.innerHTML='<main><h1>S3<span style="color:#4aa3ff">GM</span></h1><p class="intro">Setup has closed. You can close this tab.</p></main>'}};
      if(s.state==='error')note('bad','Setup stopped',s.message,null);
      else if(s.problems&&s.problems.length)note('warn','Installed, but not everything worked',s.problems.join('\n\n')+'\n\n'+s.message,close);
      else note('ok','All set!',s.message,close);
      $('go').disabled=false}
  }catch(e){}
  setTimeout(poll,600)}
$('go').onclick=async()=>{finished=false;$('result').innerHTML='';
  const r=await call('install',{gmod:$('gmod').value,disc:$('disc').value,engine:$('engine').checked});
  if(r.error){note('bad','Check this first',r.error);return}
  $('gmod').value=r.gmod;setRunning(true)};
// the Browse dialog
let mode='',cur='',picked='';
async function ls(path){const r=await call('ls?mode='+mode+'&path='+encodeURIComponent(path||''));cur=r.path;picked='';$('mpath').value=r.path;
  const L=$('mlist');L.innerHTML='';
  const add=(cls,name,fn,dbl)=>{const d=document.createElement('div');d.className='item '+cls;const i=document.createElement('span');i.className='ic';d.appendChild(i);d.appendChild(document.createTextNode(name));
    if(fn){d.onclick=()=>{for(const x of L.children)x.classList.remove('sel');d.classList.add('sel');fn()}}if(dbl)d.ondblclick=dbl;L.appendChild(d)};
  if(r.error)add('hint',r.error);
  for(const d of r.dirs)add('dir',d.name,()=>{picked=d.path;if(mode==='dir')$('mpath').value=d.path},()=>ls(d.path));
  for(const f of r.files)add('file',f.name,()=>{picked=f.path;$('mpath').value=f.path},()=>{$('mpath').value=f.path;$('mok').click()});
  if(!r.dirs.length&&!r.files.length&&!r.error)add('hint','(nothing here)');
  $('mup').onclick=()=>ls(r.parent)}
function open_(m,title,start){mode=m;$('mtitle').textContent=title;$('modal').classList.add('open');ls(start)}
$('bgmod').onclick=()=>open_('dir','Pick the garrysmod folder (inside GarrysMod)',$('gmod').value);
$('bdisc').onclick=()=>open_('file','Pick your Skate 3 disc image (.iso) or default.xex',$('disc').value);
$('mgo').onclick=()=>ls($('mpath').value);
$('mpath').onkeydown=e=>{if(e.key==='Enter')ls($('mpath').value)};
$('mcancel').onclick=()=>$('modal').classList.remove('open');
$('mok').onclick=async()=>{let v=(mode==='dir'?(picked||cur):($('mpath').value||picked));
  if(mode==='dir'){const r=await call('gmod?path='+encodeURIComponent(v));$('gmod').value=r.path}else{$('disc').value=v}
  $('modal').classList.remove('open')};
document.addEventListener('keydown',e=>{if(e.key==='Escape')$('modal').classList.remove('open')});
(async()=>{const i=await call('init');$('ver').textContent=i.version;document.title='S3GM '+i.version+' setup';
  $('gmod').value=i.gmod;$('disc').value=i.disc;$('engine').checked=i.engine;
  if(!i.gmod)setLogLines([{text:"Garry's Mod wasn't found automatically. Press Browse next to it to pick its garrysmod folder."}]);
  poll()})();
</script></body></html>
'''


def render_page(version):
    title = f'S3GM {version} setup'.replace('  ', ' ')
    return (PAGE.replace('__TITLE__', title)
            .replace('__JOST400__', setup_fonts.JOST_400).replace('__JOST700__', setup_fonts.JOST_700)).encode()


def list_folder(path, mode):
    """One folder for the Browse dialog: its sub-folders (hidden ones too, the
    Steam folders are under .local) and, for the disc, the files setup reads."""
    home = Path.home()
    try:
        folder = Path(path).expanduser() if path else home
        if folder.is_file():
            folder = folder.parent
        while not folder.is_dir() and folder != folder.parent:
            folder = folder.parent
        folder = folder.resolve()
    except OSError:
        folder = home
    dirs, files, error = [], [], None
    try:
        for entry in sorted(folder.iterdir(), key=lambda p: p.name.lower()):
            try:
                if entry.is_dir():
                    dirs.append({'name': entry.name, 'path': str(entry)})
                elif mode == 'file' and entry.suffix.lower() in ('.iso', '.xex'):
                    files.append({'name': entry.name, 'path': str(entry)})
            except OSError:
                continue
    except OSError as problem:
        error = f"Can't read this folder ({problem.strerror or problem})."
    return {'path': str(folder), 'parent': str(folder.parent), 'dirs': dirs, 'files': files, 'error': error}


class State:
    """What the install thread tells the page."""

    def __init__(self):
        self.lock = threading.Lock()
        self.lines = []
        self.state = 'idle'      # idle, running, done, error
        self.problems = []
        self.message = ''
        self.last_seen = time.time()
        self.opened = False
        self.quit = threading.Event()

    def log(self, text, err=False):
        with self.lock:
            for line in str(text).splitlines() or ['']:
                self.lines.append({'text': line, 'err': err})


def open_browser(url):
    """A plain app-style window when a Chromium-family browser is there (no
    tabs or address bar), otherwise the default browser."""
    for name in ('chromium', 'chromium-browser', 'google-chrome', 'google-chrome-stable', 'brave-browser', 'microsoft-edge'):
        exe = shutil.which(name)
        if exe:
            try:
                subprocess.Popen([exe, f'--app={url}', '--window-size=860,900'], stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
                return True
            except OSError:
                pass
    try:
        if webbrowser.open(url):
            return True
    except Exception:
        pass
    for name in ('xdg-open', 'open'):
        exe = shutil.which(name)
        if exe:
            try:
                subprocess.Popen([exe, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                return True
            except OSError:
                pass
    return False


def serve(gmod, game, hooks, show=True):
    """Runs the setup page until it is closed. `hooks` is skate3_setup's own
    pieces: version, garrysmod_in, install, workshop_copy, workshop_note.
    Returns the address (used by the tests, which pass show=False and stop it
    through the returned state)."""
    state = State()
    token = secrets.token_urlsafe(18)
    version = hooks['version']()
    page = render_page(version)

    def start_install(body):
        if state.state == 'running':
            return {'error': 'Setup is already running.'}
        raw = (body.get('gmod') or '').strip().strip('"')
        folder = hooks['garrysmod_in'](raw) if raw else None
        if folder is None:
            return {'error': "There's no Garry's Mod in that folder. Press Browse and pick the garrysmod folder inside GarrysMod."}
        picked = (body.get('disc') or '').strip().strip('"')
        if not picked or not Path(picked).exists():
            return {'error': 'Press Browse and pick your Skate 3 disc image (.iso) or default.xex.'}
        wants_engine = bool(body.get('engine'))
        with state.lock:
            state.state = 'running'
            state.problems = []
            state.message = ''

        def work():
            try:
                problems = hooks['install'](picked, folder, state.log, audio_engine=wants_engine)
                note = ('\n\n' + hooks['workshop_note']) if hooks['workshop_copy'](folder) else ''
                message = (f'All set! S3GM {version} is installed.'.replace('  ', ' ') +
                           "\n\nStart Garry's Mod, load a map and equip the Skateboard (spawn menu > Weapons > Skate 3)." + note)
                with state.lock:
                    state.problems = list(problems or [])
                    state.message = message
                    state.state = 'done'
            except Exception as error:
                import traceback
                traceback.print_exc()
                state.log('ERROR: ' + str(error), err=True)
                with state.lock:
                    state.message = str(error)
                    state.state = 'error'
        threading.Thread(target=work, daemon=True).start()
        return {'ok': True, 'gmod': str(folder)}

    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = 'S3GMSetup'

        def log_message(self, *args):
            pass

        def reply(self, code, payload, kind='application/json'):
            data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
            self.send_response(code)
            self.send_header('Content-Type', kind + ('; charset=utf-8' if kind.startswith('text/') else ''))
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.end_headers()
            self.wfile.write(data)

        def route(self, method):
            # Only our own address: no other site or host name gets an answer.
            host = (self.headers.get('Host') or '').split(':')[0]
            if host not in ('127.0.0.1', 'localhost'):
                return self.reply(403, {'error': 'no'})
            url = urllib.parse.urlsplit(self.path)
            parts = [p for p in url.path.split('/') if p]
            if not parts or not secrets.compare_digest(parts[0], token):
                return self.reply(404, {'error': 'not found'})
            state.last_seen = time.time()
            query = urllib.parse.parse_qs(url.query)
            q = lambda key, default='': (query.get(key) or [default])[0]
            if len(parts) == 1:
                state.opened = True
                return self.reply(200, page, 'text/html')
            if parts[1] != 'api' or len(parts) < 3:
                return self.reply(404, {'error': 'not found'})
            call = parts[2]
            body = {}
            if method == 'POST':
                try:
                    body = json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)) or b'{}')
                except ValueError:
                    return self.reply(400, {'error': 'bad request'})
            if call == 'init':
                return self.reply(200, {'version': version, 'gmod': str(gmod) if gmod else '',
                                        'disc': str(game) if game else '', 'engine': True})
            if call == 'ls':
                return self.reply(200, list_folder(q('path'), q('mode', 'dir')))
            if call == 'gmod':
                found = hooks['garrysmod_in'](q('path'))
                return self.reply(200, {'path': str(found or q('path'))})
            if call == 'install' and method == 'POST':
                return self.reply(200, start_install(body))
            if call == 'status':
                since = int(q('since', '0') or 0)
                with state.lock:
                    lines = state.lines[since:]
                    return self.reply(200, {'lines': lines, 'n': since + len(lines), 'state': state.state,
                                            'problems': state.problems, 'message': state.message})
            if call == 'quit' and method == 'POST':
                state.quit.set()
                return self.reply(200, {'ok': True})
            return self.reply(404, {'error': 'not found'})

        def do_GET(self):
            self.route('GET')

        def do_POST(self):
            self.route('POST')

    class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

    server = Server(('127.0.0.1', 0), Handler)
    port = server.server_address[1]
    url = f'http://127.0.0.1:{port}/{token}/'
    threading.Thread(target=server.serve_forever, daemon=True).start()
    state.url = url
    state.server = server
    if not show:
        return state
    print('Opening the S3GM setup window in your browser...', flush=True)
    if not open_browser(url):
        print('Could not open a browser by itself. Open this address in one:', flush=True)
    print(url, flush=True)
    started = time.time()
    try:
        while not state.quit.is_set():
            time.sleep(0.5)
            quiet = time.time() - state.last_seen
            if state.state != 'running':
                if state.opened and quiet > IDLE_QUIT:
                    break
                if not state.opened and time.time() - started > FIRST_LOAD_QUIT:
                    print('Nothing opened the setup page, so setup is closing. Run it again, or open the address above.', flush=True)
                    break
    except KeyboardInterrupt:
        pass
    server.shutdown()
    return state
