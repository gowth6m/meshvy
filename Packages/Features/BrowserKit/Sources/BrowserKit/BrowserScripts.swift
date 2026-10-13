import Foundation

/// The JavaScript a browser node runs on an agent's behalf.
///
/// Each snippet is the body of an async function — `callAsyncJavaScript` wraps
/// it — and every one returns a JSON *string* rather than an object, so the
/// result crosses the bridge with its types intact instead of being flattened
/// into `NSDictionary` by WebKit.
///
/// They address elements by CSS selector rather than by a numbered handle the
/// app would have to remember. A selector printed by `snapshot` is still valid
/// after the page re-renders, which numbered handles are not.
public enum BrowserScripts {
    /// Mirrors the page's console into the app. Injected at document start into
    /// every frame, so a log from an iframe arrives too.
    public static let consoleBridge = """
    (function () {
      if (window.__meshvyConsole) return;
      window.__meshvyConsole = true;
      var post = function (level, parts) {
        try {
          var text = Array.prototype.map.call(parts, function (part) {
            if (typeof part === 'string') return part;
            if (part instanceof Error) return part.message + '\\n' + (part.stack || '');
            try { return JSON.stringify(part); } catch (e) { return String(part); }
          }).join(' ');
          window.webkit.messageHandlers.meshvy.postMessage({ level: level, text: text });
        } catch (e) { /* the page is allowed to break; we are not */ }
      };
      ['log', 'info', 'warn', 'error'].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          post(level, arguments);
          if (original) original.apply(console, arguments);
        };
      });
      window.addEventListener('error', function (event) {
        post('error', [event.message + ' (' + (event.filename || '') + ':' + (event.lineno || 0) + ')']);
      });
      window.addEventListener('unhandledrejection', function (event) {
        post('error', ['Unhandled rejection: ' + (event.reason && event.reason.message || event.reason)]);
      });
    })();
    """

    /// Shared helpers, prepended to every snippet below.
    private static let helpers = """
    const esc = (value) => String(value == null ? '' : value).replace(/\\s+/g, ' ').trim();
    const escapeID = (value) => (window.CSS && CSS.escape) ? CSS.escape(value) : value;
    const unique = (selector) => {
      try { return document.querySelectorAll(selector).length === 1; } catch (e) { return false; }
    };
    const visible = (element) => {
      const box = element.getBoundingClientRect();
      if (box.width <= 0 || box.height <= 0) return false;
      const style = window.getComputedStyle(element);
      return style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
    };
    const cssPath = (element) => {
      if (element.id && unique('#' + escapeID(element.id))) return '#' + escapeID(element.id);
      const name = element.getAttribute('name');
      if (name) {
        const guess = element.tagName.toLowerCase() + '[name="' + name + '"]';
        if (unique(guess)) return guess;
      }
      const label = element.getAttribute('aria-label');
      if (label) {
        const guess = element.tagName.toLowerCase() + '[aria-label="' + label + '"]';
        if (unique(guess)) return guess;
      }
      const parts = [];
      let node = element;
      while (node && node.nodeType === 1 && parts.length < 8) {
        let part = node.tagName.toLowerCase();
        const parent = node.parentElement;
        if (!parent) { parts.unshift(part); break; }
        const twins = Array.prototype.filter.call(parent.children, (c) => c.tagName === node.tagName);
        if (twins.length > 1) part += ':nth-of-type(' + (twins.indexOf(node) + 1) + ')';
        parts.unshift(part);
        if (parent.id) { parts.unshift('#' + escapeID(parent.id)); break; }
        node = parent;
      }
      return parts.join(' > ');
    };
    const describe = (element) => {
      const tag = element.tagName.toLowerCase();
      let role = element.getAttribute('role') || tag;
      if (tag === 'input') role = 'input[' + (element.type || 'text') + ']';
      if (tag === 'a') role = 'link';
      let label = esc(
        element.getAttribute('aria-label') ||
        element.innerText ||
        element.value ||
        element.getAttribute('placeholder') ||
        element.getAttribute('title') ||
        element.getAttribute('alt') ||
        ''
      ).slice(0, 120);
      if (!label && tag === 'a') label = esc(element.getAttribute('href'));
      return {
        role: role,
        label: label,
        selector: cssPath(element),
        value: tag === 'input' || tag === 'textarea' || tag === 'select' ? esc(element.value) : null,
        disabled: !!element.disabled || element.getAttribute('aria-disabled') === 'true'
      };
    };
    const find = (selector) => {
      let element = null;
      try { element = document.querySelector(selector); } catch (e) {
        return { error: 'not a valid selector: ' + selector };
      }
      if (!element) return { error: 'nothing matches ' + selector };
      return { element: element };
    };
    """

    /// Title, readable text, and every control with a selector that addresses it.
    public static let snapshot = helpers + """
    const CONTROLS = 'a[href], button, input, textarea, select, summary, [role=button], [role=link], [role=tab], [role=checkbox], [role=switch], [onclick], [contenteditable=true]';
    const seen = new Set();
    const elements = [];
    for (const element of document.querySelectorAll(CONTROLS)) {
      if (!visible(element)) continue;
      const described = describe(element);
      if (!described.selector || seen.has(described.selector)) continue;
      seen.add(described.selector);
      elements.push(described);
      if (elements.length >= 200) break;
    }
    // innerText already drops what is hidden, which is the whole point of using
    // it over textContent here.
    const body = document.body ? document.body.innerText : '';
    return JSON.stringify({
      url: location.href,
      title: document.title,
      text: String(body || '').replace(/\\n{3,}/g, '\\n\\n').trim(),
      elements: elements
    });
    """

    public static let click = helpers + """
    const found = find(ARGS.selector);
    if (found.error) return JSON.stringify(found);
    const element = found.element;
    element.scrollIntoView({ block: 'center', inline: 'center' });
    if (element.disabled) return JSON.stringify({ error: 'that control is disabled' });
    // Focus first: a React handler bound to onFocus/onBlur sees the same order
    // it would from a real click.
    if (element.focus) element.focus();
    element.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
    element.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window }));
    element.click();
    await new Promise((resolve) => setTimeout(resolve, 150));
    return JSON.stringify({ ok: 'clicked ' + esc(describe(element).label || ARGS.selector) });
    """

    public static let type = helpers + """
    const found = find(ARGS.selector);
    if (found.error) return JSON.stringify(found);
    const element = found.element;
    element.scrollIntoView({ block: 'center' });
    if (element.focus) element.focus();
    const isField = 'value' in element && element.tagName.toLowerCase() !== 'button';
    if (isField) {
      // Assigning .value directly is invisible to React's synthetic events, so
      // go through the property's own setter and then announce it.
      const prototype = Object.getPrototypeOf(element);
      const descriptor = Object.getOwnPropertyDescriptor(prototype, 'value');
      if (descriptor && descriptor.set) descriptor.set.call(element, ARGS.text);
      else element.value = ARGS.text;
      element.dispatchEvent(new Event('input', { bubbles: true }));
      element.dispatchEvent(new Event('change', { bubbles: true }));
    } else if (element.isContentEditable) {
      element.textContent = ARGS.text;
      element.dispatchEvent(new Event('input', { bubbles: true }));
    } else {
      return JSON.stringify({ error: 'that element does not take text' });
    }
    if (ARGS.submit) {
      for (const kind of ['keydown', 'keypress', 'keyup']) {
        element.dispatchEvent(new KeyboardEvent(kind, {
          bubbles: true, cancelable: true, key: 'Enter', code: 'Enter', keyCode: 13, which: 13
        }));
      }
      const form = element.form || element.closest('form');
      if (form && !form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))) {
        /* a handler called preventDefault, which is the page's business */
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 150));
    return JSON.stringify({ ok: 'typed into ' + esc(describe(element).label || ARGS.selector) });
    """

    /// One poll of a wait: either the selector matches, or the text is on the
    /// page. Returns an error so the caller keeps waiting.
    public static let probe = helpers + """
    if (ARGS.selector) {
      let element = null;
      try { element = document.querySelector(ARGS.selector); } catch (e) {
        return JSON.stringify({ error: 'not a valid selector: ' + ARGS.selector });
      }
      if (!element || !visible(element)) return JSON.stringify({ error: 'not yet' });
      if (!ARGS.text) return JSON.stringify({ ok: 'found ' + ARGS.selector });
    }
    if (ARGS.text) {
      const body = document.body ? document.body.innerText : '';
      if (!String(body).toLowerCase().includes(String(ARGS.text).toLowerCase())) {
        return JSON.stringify({ error: 'not yet' });
      }
      return JSON.stringify({ ok: 'found “' + ARGS.text + '” on the page' });
    }
    return JSON.stringify({ error: 'nothing to wait for' });
    """
}
