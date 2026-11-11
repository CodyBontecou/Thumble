const waiting = new Map();
let sequence = 0;
let qtHost;
let qtReady;

// Both native hosts deliver data through this single response surface. No strings
// from a profile are evaluated as JavaScript or used as markup.
window.thumbleResponse = value => {
  const reply = typeof value === 'string' ? JSON.parse(value) : value;
  const entry = waiting.get(reply.id);
  if (!entry) return;
  clearTimeout(entry.timer); waiting.delete(reply.id);
  if (reply.error) entry.reject(Error(reply.error)); else entry.resolve(reply.result);
};

function qt() {
  if (!qtReady) qtReady = new Promise((resolve, reject) => {
    if (!window.qt?.webChannelTransport || !window.QWebChannel) return reject(Error('Desktop bridge is unavailable. Restart Thumble.'));
    new window.QWebChannel(window.qt.webChannelTransport, channel => {
      qtHost = channel.objects.workspace;
      qtHost.response.connect(window.thumbleResponse);
      resolve(qtHost);
    });
  });
  return qtReady;
}

export async function request(operation, payload = {}) {
  if (window.thumblePreviewHost) return window.thumblePreviewHost(operation, payload);
  const id = `workspace-${++sequence}`;
  const message = { id, operation, payload };
  if (!window.webkit?.messageHandlers?.workspace) await qt();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { waiting.delete(id); reject(Error('The receiver did not respond. Your unsaved changes are still here.')); }, 15000);
    waiting.set(id, { resolve, reject, timer });
    try {
      if (qtHost) qtHost.request(JSON.stringify(message));
      else window.webkit.messageHandlers.workspace.postMessage(message);
    } catch (error) { clearTimeout(timer); waiting.delete(id); reject(error); }
  });
}
