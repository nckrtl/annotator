import CoreGraphics
import Foundation

/// The DOM element under the cursor, read over the Chrome DevTools Protocol.
/// The fields match the web annotator (`@nckrtl/annotator`), so agents read native and web records alike.
public struct DOMInfo: Codable, Sendable, Equatable {
    /// The web annotator's element name, such as `button "Save"` or `rounded lg`.
    public var name: String
    /// The web annotator's element path, such as `.settings-row > button`.
    public var path: String
    public var tag: String
    /// A CSS selector that finds this element in the page.
    public var selector: String
    /// The opening tag plus a short text excerpt.
    public var html: String
    /// The element's frame in page viewport points (zoom applied).
    public var rect: Rect
    /// `file:line` of the nearest app component, from React's debug info.
    public var component: String?
    /// The nearest React components, outermost first: `<Settings> <Row>`.
    public var react: String?
    public var components: [Frame]
    public var appearance: Appearance

    public struct Rect: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }

    public struct Frame: Codable, Sendable, Equatable {
        public var name: String
        public var file: String?
        public var line: Int?
    }

    public struct Appearance: Codable, Sendable, Equatable {
        public var classes: [String]
        public var computed: [String: String]
        public var utilities: [String: String]
    }

    /// The element's frame in global top-left screen points. `viewport` is the page's web area on screen.
    public func screenFrame(viewport: CGRect) -> CGRect {
        CGRect(x: viewport.minX + rect.x, y: viewport.minY + rect.y, width: rect.width, height: rect.height)
    }

    /// The JavaScript that finds and describes the element at (`x`, `y`), given in viewport points.
    /// `scale` is the display's pixels per point; with `devicePixelRatio` it gives the page zoom.
    /// It returns a JSON string of `DOMInfo`, or `null`.
    public static func probe(x: Double, y: Double, scale: Double) -> String {
        "(\(probeFunction))(\(x), \(y), \(scale))"
    }

    public static func decode(_ json: String) throws -> DOMInfo? {
        guard json != "null", json.utf8.count <= 65_536 else { return nil }
        return try JSONDecoder().decode(DOMInfo.self, from: Data(json.utf8)).clamped
    }

    /// Bounds every string and strips values a password field or a hooked page might have put in the HTML.
    public var clamped: DOMInfo {
        var copy = self
        copy.name = AXElementInfo.truncate(name, to: 200)
        copy.path = AXElementInfo.truncate(path, to: 300)
        copy.selector = AXElementInfo.truncate(selector, to: 300)
        copy.html = DOMInfo.redact(html)
        copy.component = component.map { AXElementInfo.truncate($0, to: 200) }
        copy.react = react.map { AXElementInfo.truncate($0, to: 200) }
        copy.components = Array(components.prefix(12)).map { frame in
            Frame(name: AXElementInfo.truncate(frame.name, to: 80), file: frame.file.map { AXElementInfo.truncate($0, to: 200) }, line: frame.line)
        }
        return copy
    }

    /// Drops `value` and `src` attributes, then keeps the first 300 characters.
    public static func redact(_ html: String) -> String {
        let stripped = html.replacingOccurrences(
            of: #"(?i)(?:\s(?:value|src)\s*=\s*)(?:"[^"]*"|'[^']*'|[^\s>]+)"#,
            with: "",
            options: .regularExpression)
        return AXElementInfo.truncate(stripped, to: 300)
    }

    /// A compact port of the web annotator's `identify.ts`, `react-inspect.ts` and `appearance.ts`.
    static let probeFunction = #"""
        function (X, Y, SCALE) {
          const zoom = (window.devicePixelRatio || SCALE) / SCALE;
          const cx = X / zoom, cy = Y / zoom;
          let el = document.elementFromPoint(cx, cy);
          while (el && el.shadowRoot) {
            const inner = el.shadowRoot.elementFromPoint(cx, cy);
            if (!inner || inner === el) break;
            el = inner;
          }
          if (!el) return "null";

          const text = (node) => (node.textContent || "").trim().replace(/\s+/g, " ");
          const parentOf = (node) => node.parentElement || (node.getRootNode && node.getRootNode().host) || null;
          const meaningful = (v) => v.length > 2 && !/^[a-z]{1,2}$/.test(v) && !/[A-Z0-9]{5,}/.test(v);
          const classes = typeof el.className === "string" ? el.className.split(/\s+/).filter(Boolean) : [];

          function name(t) {
            const tag = t.tagName.toLowerCase();
            const s = text(t);
            if (t.dataset && t.dataset.element) return t.dataset.element;
            if (["path", "circle", "rect", "line", "g"].includes(tag)) {
              const svg = t.closest("svg");
              const p = svg && parentOf(svg);
              return p ? "graphic in " + name(p) : "graphic element";
            }
            if (tag === "svg") {
              const p = parentOf(t);
              if (p && p.tagName.toLowerCase() === "button") return text(p) ? `icon in "${text(p)}" button` : "button icon";
              return "icon";
            }
            if (tag === "button") {
              const label = t.getAttribute("aria-label");
              if (label) return `button [${label}]`;
              return s ? `button "${s.slice(0, 25)}"` : "button";
            }
            if (tag === "a") {
              const href = t.getAttribute("href");
              if (s) return `link "${s.slice(0, 25)}"`;
              return href ? `link to ${href.slice(0, 30)}` : "link";
            }
            if (tag === "input") {
              const placeholder = t.getAttribute("placeholder"), n = t.getAttribute("name");
              if (placeholder) return `input "${placeholder}"`;
              if (n) return `input [${n}]`;
              return (t.getAttribute("type") || "text") + " input";
            }
            if (/^h[1-6]$/.test(tag)) return s ? `${tag} "${s.slice(0, 35)}"` : tag;
            if (tag === "p") return s ? `paragraph: "${s.slice(0, 40)}${s.length > 40 ? "..." : ""}"` : "paragraph";
            if (tag === "span" || tag === "label") return s && s.length < 40 ? `"${s}"` : tag;
            if (tag === "li") return s && s.length < 40 ? `list item: "${s.slice(0, 35)}"` : "list item";
            if (tag === "code") return s && s.length < 30 ? "code: `" + s + "`" : "code";
            if (tag === "pre") return "code block";
            if (tag === "img") { const alt = t.getAttribute("alt"); return alt ? `image "${alt.slice(0, 30)}"` : "image"; }
            if (["div", "section", "article", "nav", "header", "footer", "aside", "main"].includes(tag)) {
              const label = t.getAttribute("aria-label"), role = t.getAttribute("role");
              if (label) return `${tag} [${label}]`;
              if (role) return role;
              const cls = typeof t.className === "string" ? t.className : "";
              const words = cls.split(/[\s_-]+/).map((v) => v.replace(/[A-Z0-9]{5,}.*$/, "")).filter(meaningful).slice(0, 2);
              if (words.length) return words.join(" ");
              return tag === "div" ? "container" : tag;
            }
            return s && s.length < 40 ? `"${s}"` : tag;
          }

          function path(t) {
            const parts = [];
            let cur = t, depth = 0;
            while (cur && depth < 4) {
              const tag = cur.tagName.toLowerCase();
              if (tag === "html" || tag === "body") break;
              let id = tag;
              const cls = typeof cur.className === "string" ? cur.className : "";
              const good = cls.split(/\s+/).find((v) => meaningful(v) || v.includes("/"));
              if (good) id = "." + good.split("_")[0];
              else if (cur.id) id = "#" + cur.id;
              const next = parentOf(cur);
              if (id === "div" || id === "span") { cur = next; continue; }
              parts.unshift(id);
              cur = next;
              depth += 1;
            }
            return parts.join(" > ");
          }

          function selector(t) {
            const parts = [];
            let cur = t;
            while (cur && cur.nodeType === 1 && cur.tagName.toLowerCase() !== "html") {
              const tag = cur.tagName.toLowerCase();
              if (cur.id && /^[A-Za-z][\w-]*$/.test(cur.id)) { parts.unshift(`${tag}#${cur.id}`); break; }
              const parent = cur.parentElement;
              if (!parent) { parts.unshift(tag); break; }
              const same = Array.from(parent.children).filter((c) => c.tagName === cur.tagName);
              parts.unshift(same.length > 1 ? `${tag}:nth-of-type(${same.indexOf(cur) + 1})` : tag);
              cur = parent;
            }
            return parts.join(" > ");
          }

          function html(t) {
            const tag = t.tagName.toLowerCase();
            const type = (t.getAttribute("type") || "").toLowerCase();
            if ((tag === "input" || tag === "textarea") && (type === "password" || type === "hidden")) {
              return `<${tag} type="${type}">`;
            }
            let open = t.cloneNode(false).outerHTML.replace(/<\/[^>]+>$/, "");
            open = open.replace(/\s(?:value|src)=("[^"]*"|'[^']*'|[^\s>]+)/gi, "");
            const s = text(t);
            return (open.length > 300 ? open.slice(0, 299) + "…" : open) + (s ? " " + (s.length > 120 ? s.slice(0, 119) + "…" : s) : "");
          }

          const SKIP = /^(Inertia|Head|Fragment|Suspense|StrictMode|Slot|Primitive|Presence|VisuallyHidden)$|Context$|Provider$/;
          function fiberOf(node) {
            const key = Object.getOwnPropertyNames(node).find((k) => k.startsWith("__reactFiber$") || k.startsWith("__reactInternalInstance$"));
            return key ? node[key] : null;
          }
          function componentName(type) {
            if (typeof type === "function") return type.displayName || type.name || null;
            if (type && typeof type === "object") return type.displayName || type.name || (type.render && (type.render.displayName || type.render.name)) || null;
            return null;
          }
          function cleanFile(file) {
            return file.replace(/^file:\/\//, "").replace(/^[a-z][\w+.-]*:\/\/[^/]*\//i, "").replace(/\?.*$/, "");
          }
          function source(fiber) {
            const d = fiber._debugSource || (fiber.memoizedProps && fiber.memoizedProps.__source);
            if (d && d.fileName) return { file: cleanFile(d.fileName), line: d.lineNumber };
            const st = fiber._debugStack;
            const stack = typeof st === "string" ? st : st && st.stack;
            if (!stack) return null;
            for (const frame of stack.split("\n")) {
              if (/node_modules|jsx-dev-runtime|jsx-runtime|react-stack-bottom-frame|react-dom/.test(frame)) continue;
              const m = frame.match(/(\S+?\.(?:tsx|jsx|ts|js|vue))(?:\?[^:\s)]*)?:(\d+)(?::\d+)?/);
              if (m) return { file: cleanFile(m[1].replace(/^\(/, "")), line: Number(m[2]) };
            }
            return null;
          }
          const frames = [];
          let fiber = fiberOf(el);
          if (!fiber) {
            let up = parentOf(el);
            while (up && !fiber) { fiber = fiberOf(up); up = parentOf(up); }
          }
          for (let f = fiber, i = 0; f && i < 60 && frames.length < 12; f = f.return, i++) {
            const n = componentName(f.type);
            if (!n || SKIP.test(n)) continue;
            const src = source(f);
            frames.push({ name: n, file: src ? src.file : undefined, line: src ? src.line : undefined });
          }
          const primitive = (file) => /(?:^|\/)components\/ui\//.test(file);
          const app = frames.find((f) => f.file && !primitive(f.file)) || frames.find((f) => f.file);
          const react = frames.length ? frames.slice(0, 3).reverse().map((f) => `<${f.name}>`).join(" ") : null;

          const COMPUTED = ["fontSize", "fontWeight", "lineHeight", "letterSpacing", "color", "backgroundColor",
            "padding", "paddingTop", "paddingRight", "paddingBottom", "paddingLeft"];
          const styles = getComputedStyle(el), computed = {};
          for (const p of COMPUTED) {
            const v = styles[p];
            if (v && v !== "0px" && v !== "normal" && v !== "rgba(0, 0, 0, 0)") computed[p] = v;
          }
          const utilities = {};
          for (const v of classes) {
            if (/^text-(?:xs|sm|base|lg|xl|[2-9]xl)$/.test(v)) utilities.type = v;
            else if (/^p[xytblr]?-(?:\d+(?:\.\d+)?|px)$/.test(v)) utilities.padding = utilities.padding || v;
            else if (/^(?:m[xytblr]?|gap(?:-[xy])?)-(?:\d+(?:\.\d+)?|px)$/.test(v)) utilities.spacing = utilities.spacing || v;
            else if (/^tracking-/.test(v)) utilities.tracking = v;
            else if (/^font-(?:thin|extralight|light|normal|medium|semibold|bold|extrabold|black)$/.test(v)) utilities.weight = v;
            else if (/^bg-(?:background|card|muted|primary|secondary|accent|destructive|popover)$/.test(v)) utilities.background = v;
            else if (/^max-w-/.test(v)) utilities.width = v;
            else if (/^w-(?:\d+|px|full|fit|auto|screen)$/.test(v)) utilities.width = utilities.width || v;
          }

          const r = el.getBoundingClientRect();
          return JSON.stringify({
            name: name(el), path: path(el), tag: el.tagName.toLowerCase(), selector: selector(el), html: html(el),
            rect: { x: r.left * zoom, y: r.top * zoom, width: r.width * zoom, height: r.height * zoom },
            component: app ? (app.line ? `${app.file}:${app.line}` : app.file) : null,
            react, components: frames, appearance: { classes, computed, utilities },
          });
        }
        """#
}

/// The Chrome DevTools port advertised on a process command line.
public enum DevToolsLaunch {
    public static func port(in arguments: [String]) -> UInt16? {
        for (index, argument) in arguments.enumerated() {
            let flag = "--remote-debugging-port"
            if argument.hasPrefix(flag + "=") {
                return UInt16(argument.dropFirst(flag.count + 1))
            }
            if argument == flag, index + 1 < arguments.count {
                return UInt16(arguments[index + 1])
            }
        }
        return nil
    }
}

/// A DevTools WebSocket that stays on the loopback port we already checked.
public enum DebuggerEndpoint {
    public static func socket(from string: String, port: UInt16) -> URL? {
        guard let url = URL(string: string),
            let scheme = url.scheme, scheme == "ws" || scheme == "wss",
            let host = url.host()?.lowercased(), ServiceURL.isLoopback(host),
            url.port == Int(port)
        else { return nil }
        return url
    }
}

/// Picks the DevTools page target that shows `url`.
public enum DevToolsTargets {
    public struct Target: Decodable, Sendable, Equatable {
        public var type: String
        public var url: String
        public var title: String?
        public var webSocketDebuggerUrl: String?

        public init(type: String, url: String, title: String?, webSocketDebuggerUrl: String?) {
            self.type = type
            self.url = url
            self.title = title
            self.webSocketDebuggerUrl = webSocketDebuggerUrl
        }
    }

    /// The page that shows `url`: an exact match first, then a match without the `#` part (hash routers
    /// change it without DevTools noticing). The window title decides between pages with the same URL.
    /// With no match and exactly one page, that page. DevTools' own pages never count.
    /// Nil when the choice is not clear: then the caller uses accessibility only.
    public static func pick(_ targets: [Target], url: String?, title: String? = nil) -> Target? {
        let pages = targets.filter {
            // `webview` covers Electron <webview> guests, such as the tabs of Conn's integrated browser.
            ["page", "webview"].contains($0.type) && $0.webSocketDebuggerUrl != nil && !$0.url.hasPrefix("devtools://")
        }
        func trimmed(_ value: String) -> String { value.hasSuffix("/") ? String(value.dropLast()) : value }
        func base(_ value: String) -> String { trimmed(String(value.split(separator: "#", maxSplits: 1).first ?? "")) }
        func choose(_ matches: [Target]) -> Target? {
            if matches.count == 1 { return matches[0] }
            let titled = matches.filter { $0.title == title }
            return titled.count == 1 ? titled[0] : nil
        }
        if let url {
            let exact = pages.filter { trimmed($0.url) == trimmed(url) }
            if !exact.isEmpty { return choose(exact) }
            let loose = pages.filter { base($0.url) == base(url) }
            if !loose.isEmpty { return choose(loose) }
        }
        return pages.count == 1 ? pages[0] : nil
    }
}
