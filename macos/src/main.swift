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
        // Both of these sit behind the Faculty button now: setting up a machine and
        // proctoring from the dashboard are two halves of the same job, and neither
        // is anything a student should be poking at. The settings panel still asks
        // for the admin password — the button is only about where it lives.
        if body == "admin" { launchAdmin() }
        if body == "faculty" { openDashboard() }
    }

    /// Ask lockedin_config.py for one value. Used to find the dashboard URL, which
    /// lives in the settings file rather than being baked into this binary.
    func configValue(_ arguments: [String]) -> String? {
        guard let res = Bundle.main.resourcePath,
              let runner = AppDelegate.pythonRunner() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: runner.exe)
        p.arguments = runner.args + [res + "/lockedin_config.py"] + arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run server/serve.py --ensure: start the local dashboard server if it is not
    /// already up, and hand back the address to open. Returns nil if that failed —
    /// no uv, no serve.py, no network — and the caller falls back to the alert.
    func ensureDashboardServer() -> String? {
        guard let res = Bundle.main.resourcePath,
              let runner = AppDelegate.pythonRunner(),
              FileManager.default.fileExists(atPath: res + "/serve.py") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: runner.exe)
        p.arguments = runner.args + [res + "/serve.py", "--ensure"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              out.hasPrefix("http") else { return nil }
        return out
    }

    /// Is this address one that only exists while our own server is running? Those
    /// are the ones worth starting on demand — and worth re-asking for, because the
    /// machine's wi-fi address changes with the DHCP lease and the saved one goes
    /// stale without anything looking wrong.
    static func isLocallyServed(_ address: String) -> Bool {
        guard let host = URL(string: address)?.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") {
            return true
        }
        // 172.16.0.0/12 — the third private range, and the fiddly one to spell.
        let parts = host.split(separator: ".")
        if parts.count == 4, parts[0] == "172", let second = Int(parts[1]),
           (16...31).contains(second) { return true }
        return false
    }

    /// The proctor side is a web page, so this just opens it in the default browser.
    func openDashboard() {
        // get-cloud prints JSON; pulling one field out of it with JSONSerialization
        // beats adding a second CLI verb for every setting the launcher might want.
        var dashboard = ""
        if let json = configValue(["get-cloud"]),
           let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dashboard = (object["dashboard_url"] as? String) ?? ""
        }
        // Three shapes are all legitimate here, because SETUP.md offers all three:
        // a published https page, a file:// URL, or a plain path to the .html on disk
        // for a proctor who just opens the file.
        // A saved address on this machine's own network means the page is served by
        // server/serve.py, which is not running yet if nobody started it. Start it,
        // and use the address it reports rather than the saved one.
        if dashboard.isEmpty || AppDelegate.isLocallyServed(dashboard) {
            if let served = ensureDashboardServer() { dashboard = served }
        }
        if !dashboard.isEmpty {
            var target: URL? = nil
            if dashboard.hasPrefix("/") {
                target = URL(fileURLWithPath: dashboard)
            } else if let url = URL(string: dashboard),
                      ["http", "https", "file"].contains(url.scheme ?? "") {
                target = url
            }
            if let url = target {
                NSWorkspace.shared.open(url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
                return
            }
        }
        alert("Could not open the dashboard",
              "The proctor dashboard is a web page, and this Mac has no address for "
              + "it.\n\nGo back to Faculty > Exam settings > Proctoring and press "
              + "\"Serve on this network\" — that publishes it on your wi-fi, so you "
              + "can watch from a phone or a second laptop as well as from here.\n\n"
              + "If that button does nothing, uv is probably not installed; you can "
              + "still open server/dashboard/index.html directly in a browser.")
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
  .picks { display: flex; flex-direction: column; gap: 12px; margin: 18px 0 6px; }
  .pick { text-align: left; padding: 16px 18px; border-radius: 14px; cursor: pointer;
          background: rgba(74,222,128,.07); border: 1px solid rgba(74,222,128,.3);
          transition: border-color .18s ease, background .18s ease; }
  .pick:hover { border-color: #4ade80; background: rgba(74,222,128,.14); }
  .pick .pl { font-size: 17px; font-weight: 700; color: #eafff0; }
  .pick .pd { font-size: 13px; color: #9ffcbf; opacity: .85; margin-top: 5px; line-height: 1.5; }
  .alt { margin-top: 6px; font-size: 13px; color: #7fe0a0; opacity: .65; cursor: pointer;
         letter-spacing: 1px; padding: 8px 12px; border-radius: 10px; }
  .alt:hover { opacity: 1; }
</style>
</head>
<body>
  <canvas id="matrix"></canvas>
  <div class="veil"></div>

  <div class="wrap">
    <div class="badge">// study mode engaged</div>
    <h1>LOCKED IN &#128274;</h1>
    <div class="sub">who's signing in?</div>
    <div class="btns">
      <div class="btn" onclick="pick('student')">
        <div class="ico">&#127891;</div>
        <div class="lbl">Student</div>
        <div class="hint">check in &amp; start the exam</div>
      </div>
      <div class="btn" onclick="showFaculty()">
        <div class="ico">&#128104;&#8205;&#127979;</div>
        <div class="lbl">Faculty</div>
        <div class="hint">monitor &amp; set up this Mac</div>
      </div>
    </div>
    <div class="alt" onclick="showWin()">on Windows? &#128421;&#65039;</div>
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

  <div class="overlay" id="facOverlay">
    <div class="card">
      <h2>Faculty &#128104;&#8205;&#127979;</h2>
      <p>Two halves of the job. Both ask you to sign in.</p>
      <div class="picks">
        <div class="pick" onclick="pick('faculty')">
          <div class="pl">&#128200;&nbsp; Proctor dashboard</div>
          <div class="pd">Create exams and join codes, approve students, watch the live grid. Opens in your browser.</div>
        </div>
        <div class="pick" onclick="pick('admin')">
          <div class="pl">&#9881;&#65039;&nbsp; Exam settings</div>
          <div class="pd">Allowed sites, unlock passcode, what gets recorded, and the Supabase project. Same settings on Mac and Windows. Needs the admin password.</div>
        </div>
      </div>
      <button class="close" onclick="hideFac()">never mind</button>
    </div>
  </div>

<script>
  // 'student' is the old 'macos' path: it starts the lockdown, which now runs the
  // check-in first whenever this machine is set up for proctored exams.
  function pick(role) {
    var message = role === 'student' ? 'macos' : role;
    try { window.webkit.messageHandlers.bridge.postMessage(message); } catch (e) {}
  }
  function showWin() { document.getElementById('winOverlay').style.display = 'flex'; }
  function hideWin() { document.getElementById('winOverlay').style.display = 'none'; }
  function showFaculty() { document.getElementById('facOverlay').style.display = 'flex'; }
  function hideFac() { document.getElementById('facOverlay').style.display = 'none'; }

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
