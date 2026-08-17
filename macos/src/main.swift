import Cocoa
import WebKit

class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var webView: WKWebView!

    func applicationDidFinishLaunching(_ note: Notification) {
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let w: CGFloat = 1280, h: CGFloat = 820
        let rect = NSRect(x: screen.midX - w/2, y: screen.midY - h/2, width: w, height: h)

        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Locked In"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.fullScreenPrimary]

        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "bridge")
        config.userContentController = ucc

        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(webView)
        webView.loadHTMLString(AppDelegate.html, baseURL: nil)

        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? String else { return }
        if body == "macos" { launchMac() }
        if body == "admin" { launchAdmin() }
    }

    /// Where to find uv (preferred — it installs the script's own dependencies) or a
    /// plain python3. A double-clicked .app gets no login shell, so PATH is no use
    /// here and the usual install locations have to be checked directly.
    static func pythonRunner() -> (exe: String, args: [String])? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        for uv in ["\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"] {
            if fm.isExecutableFile(atPath: uv) { return (uv, ["run", "--script"]) }
        }
        for py in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            if fm.isExecutableFile(atPath: py) { return (py, []) }
        }
        return nil
    }

    func alert(_ title: String, _ detail: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.alertStyle = .warning
        a.runModal()
    }

    /// Open the settings panel (allowed sites, passcode, recording options).
    func launchAdmin() {
        guard let res = Bundle.main.resourcePath else { return }
        guard let runner = AppDelegate.pythonRunner() else {
            alert("Locked In needs Python",
                  "The admin panel runs on Python. Install uv, then try again:\n\n"
                  + "curl -LsSf https://astral.sh/uv/install.sh | sh")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: runner.exe)
        p.arguments = runner.args + [res + "/admin_panel.py"]
        // A panel that dies on startup (no Tk in that interpreter, for instance) would
        // otherwise just look like a button that does nothing.
        p.terminationHandler = { proc in
            guard proc.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                self.alert("The admin panel could not open",
                           "Exit code \(proc.terminationStatus). If you are using a plain "
                           + "python3, it may have been built without Tk — installing uv "
                           + "is the easier fix.")
            }
        }
        do { try p.run() } catch {
            alert("The admin panel could not open", error.localizedDescription)
        }
    }

    func launchMac() {
        guard let res = Bundle.main.resourcePath else { return }
        let script = res + "/guided-access.command"
        let inner = "chmod +x \\\"\(script)\\\" && \\\"\(script)\\\""
        let osa = "tell application \"Terminal\" to do script \"\(inner)\""
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", "tell application \"Terminal\" to activate", "-e", osa]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
    }

    static let html = """
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { height: 100%; overflow: hidden; background: #000; font-family: 'SF Mono', ui-monospace, Menlo, Consolas, monospace; }
  #matrix { position: fixed; inset: 0; z-index: 0; }
  .veil { position: fixed; inset: 0; z-index: 1; background: radial-gradient(ellipse at center, rgba(0,0,0,0.35) 0%, rgba(0,0,0,0.82) 70%, rgba(0,0,0,0.95) 100%); }
  .wrap { position: fixed; inset: 0; z-index: 2; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 34px; padding: 24px; }
  .badge { font-size: 13px; letter-spacing: 4px; color: #4ade80; opacity: .85; text-transform: uppercase; }
  h1 { font-size: clamp(48px, 9vw, 118px); font-weight: 800; letter-spacing: 2px;
       color: #eafff0; text-shadow: 0 0 18px rgba(74,222,128,.75), 0 0 42px rgba(34,197,94,.45); }
  .sub { font-size: clamp(15px, 2.2vw, 22px); color: #9ffcbf; opacity: .9; margin-top: -14px; }
  .btns { display: flex; gap: 26px; flex-wrap: wrap; justify-content: center; margin-top: 12px; }
  .btn { position: relative; width: 260px; padding: 26px 20px; border-radius: 18px; cursor: pointer;
         background: rgba(10, 20, 14, 0.55); border: 1px solid rgba(74,222,128,.35);
         backdrop-filter: blur(8px); transition: transform .15s ease, box-shadow .2s ease, border-color .2s ease;
         display: flex; flex-direction: column; align-items: center; gap: 12px; }
  .btn:hover { transform: translateY(-4px); border-color: #4ade80; box-shadow: 0 0 28px rgba(74,222,128,.35); }
  .btn .ico { font-size: 52px; }
  .btn .lbl { font-size: 22px; font-weight: 700; color: #eafff0; letter-spacing: 1px; }
  .btn .hint { font-size: 12px; color: #7fe0a0; opacity: .8; }
  .foot { z-index: 2; position: fixed; bottom: 22px; font-size: 12px; color: #4ade80; opacity: .55; letter-spacing: 1px; }
  .overlay { position: fixed; inset: 0; z-index: 5; display: none; align-items: center; justify-content: center; background: rgba(0,0,0,.85); backdrop-filter: blur(6px); }
  .card { max-width: 560px; background: #06120b; border: 1px solid rgba(74,222,128,.4); border-radius: 20px; padding: 34px; color: #d7ffe6; box-shadow: 0 0 40px rgba(74,222,128,.25); }
  .card h2 { color: #4ade80; margin-bottom: 14px; font-size: 26px; }
  .card p { line-height: 1.6; margin-bottom: 10px; font-size: 15px; }
  .card code { background: rgba(74,222,128,.12); padding: 2px 7px; border-radius: 6px; color: #9ffcbf; }
  .close { margin-top: 18px; padding: 12px 22px; border-radius: 12px; border: 1px solid #4ade80; background: transparent; color: #eafff0; font-size: 15px; cursor: pointer; font-family: inherit; }
  .close:hover { background: rgba(74,222,128,.15); }
  .admin { position: fixed; top: 18px; right: 20px; z-index: 3; cursor: pointer; font-size: 13px;
           letter-spacing: 1px; color: #7fe0a0; opacity: .6; padding: 8px 14px; border-radius: 10px;
           border: 1px solid rgba(74,222,128,.25); transition: opacity .15s ease, border-color .2s ease; }
  .admin:hover { opacity: 1; border-color: #4ade80; }
</style>
</head>
<body>
  <canvas id="matrix"></canvas>
  <div class="veil"></div>
  <div class="admin" onclick="pick('admin')">&#9881;&#65039; Admin</div>

  <div class="wrap">
    <div class="badge">// study mode engaged</div>
    <h1>LOCKED IN &#128274;</h1>
    <div class="sub">yo. where we locking in today?</div>
    <div class="btns">
      <div class="btn" onclick="pick('macos')">
        <div class="ico"><svg viewBox="0 0 384 512" width="54" height="54" fill="#eafff0"><path d="M318.7 268.7c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141.2 4 184.8 4 273.5q0 39.3 14.4 81.2c12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.7 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-91.9zm-56.6-164.2c27.3-32.4 24.8-61.9 24-72.5-24.1 1.4-52 16.4-67.9 34.9-17.5 19.8-27.8 44.3-25.6 71.9 26.1 2 49.9-11.4 69.5-34.3z"/></svg></div>
        <div class="lbl">macOS</div>
        <div class="hint">run it now</div>
      </div>
      <div class="btn" onclick="pick('windows')">
        <div class="ico"><svg viewBox="0 0 448 512" width="52" height="52" fill="#eafff0"><path d="M0 93.7l183.6-25.3v177.4H0V93.7zm0 324.6l183.6 25.3V268.4H0v149.9zm203.8 28L448 480V268.4H203.8v177.9zm0-380.6v180.1H448V32L203.8 65.7z"/></svg></div>
        <div class="lbl">Windows</div>
        <div class="hint">how to run</div>
      </div>
    </div>
  </div>

  <div class="foot">no cap. only the assignment. touch grass later.</div>

  <div class="overlay" id="winOverlay">
    <div class="card">
      <h2>Windows setup &#128421;&#65039;</h2>
      <p>This Mac app can't run the Windows version directly.</p>
      <p>On your Windows PC, put <code>LockedIn.hta</code> and <code>guided-access.ps1</code> in the same folder, then double-click <code>LockedIn.hta</code>, pick Windows, and approve the admin prompt.</p>
      <button class="close" onclick="hideWin()">bet, got it</button>
    </div>
  </div>

<script>
  function pick(os) {
    if (os === 'windows') { document.getElementById('winOverlay').style.display = 'flex'; return; }
    try { window.webkit.messageHandlers.bridge.postMessage(os === 'admin' ? 'admin' : 'macos'); } catch (e) {}
  }
  function hideWin() { document.getElementById('winOverlay').style.display = 'none'; }

  const canvas = document.getElementById('matrix');
  const ctx = canvas.getContext('2d');
  function resize() { canvas.width = window.innerWidth; canvas.height = window.innerHeight; }
  resize();
  window.addEventListener('resize', resize);
  const glyphs = 'アカサタナハマヤラワ0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ<>[]{}=+*/#$%&'.split('');
  const font = 16;
  let cols = Math.floor(canvas.width / font);
  let drops = new Array(cols).fill(1);
  function draw() {
    ctx.fillStyle = 'rgba(0,0,0,0.08)';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.fillStyle = '#22c55e';
    ctx.font = font + 'px monospace';
    for (let i = 0; i < drops.length; i++) {
      const ch = glyphs[Math.floor(Math.random() * glyphs.length)];
      const x = i * font;
      const y = drops[i] * font;
      ctx.fillStyle = Math.random() > 0.975 ? '#eafff0' : '#22c55e';
      ctx.fillText(ch, x, y);
      if (y > canvas.height && Math.random() > 0.975) drops[i] = 0;
      drops[i]++;
    }
  }
  setInterval(draw, 45);
</script>
</body>
</html>
"""
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
NSApp.setActivationPolicy(.regular)
app.run()
