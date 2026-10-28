// Stateless relay: keeps only live sockets in RAM. No DB, no logs, no message storage.
const { WebSocketServer } = require('ws');
const wss = new WebSocketServer({ port: process.env.PORT || 8080 });
const peers = new Map();
wss.on('connection', ws => {
  ws.on('message', d => {
    let m; try { m = JSON.parse(d); } catch { return; }
    if (m.reg) { peers.set(m.reg, ws); ws.id = m.reg; return; }
    if (m.to && ws.id) {
      const t = peers.get(m.to);
      if (t && t.readyState === 1) t.send(JSON.stringify({ from: ws.id, p: m.p })); // opaque ciphertext
    }
  });
  ws.on('close', () => { if (ws.id && peers.get(ws.id) === ws) peers.delete(ws.id); });
});
