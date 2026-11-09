// Smoke test for a running self-hosted buzzer server (#103): a test host opens
// a room, a phone joins with its Game PIN and buzzes, the host drops and
// resumes within the grace period, then closes the room.
//
//   node scripts/smoke-test.mjs <server URL> <host token>
//   node scripts/smoke-test.mjs http://127.0.0.1:8472 "$MACPARDY_HOST_TOKEN"
//   node scripts/smoke-test.mjs https://macpardy.example.duckdns.org "$TOKEN"
//
// Needs Node 22 or later (global WebSocket). Exits non-zero on failure.

const [base, token] = process.argv.slice(2);
if (!base || !token) {
  console.error("usage: node scripts/smoke-test.mjs <server URL> <host token>");
  process.exit(64);
}
const wsBase = base.replace(/^http/, "ws").replace(/\/$/, "");
const teamID = "6F1A6D2E-6C4B-4E59-9A55-0F5B1D3C2A11";

function client(path, label) {
  const socket = new WebSocket(`${wsBase}${path}`);
  const messages = [];
  const waiters = [];
  socket.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    if (msg.type === "ping") {
      socket.send(JSON.stringify({ type: "pong" }));
      return;
    }
    messages.push(msg);
    for (const waiter of [...waiters]) waiter();
  };
  const opened = new Promise((resolve, reject) => {
    socket.onopen = resolve;
    socket.onerror = () => reject(new Error(`${label}: couldn't connect to ${wsBase}${path}`));
  });
  const closed = new Promise((resolve) => { socket.onclose = resolve; });
  return {
    opened, closed, messages,
    send: (msg) => socket.send(JSON.stringify(msg)),
    close: () => socket.close(1000),
    /// Resolves with the first message (seen so far or later) matching `test`.
    waitFor(test, what, timeout = 5000) {
      return new Promise((resolve, reject) => {
        const check = () => {
          const found = messages.find(test);
          if (found) {
            waiters.splice(waiters.indexOf(check), 1);
            clearTimeout(timer);
            resolve(found);
          }
        };
        const timer = setTimeout(() => {
          waiters.splice(waiters.indexOf(check), 1);
          reject(new Error(`${label}: timed out waiting for ${what}; got ${JSON.stringify(messages.map((m) => m.type))}`));
        }, timeout);
        waiters.push(check);
        check();
      });
    },
  };
}

const step = (text) => console.log(`✓ ${text}`);

// 1. Host opens a room.
const host = client("/host", "host");
await host.opened;
host.send({ type: "hello", payload: { token, version: 1, client: "smoke-test" } });
const opened = (await host.waitFor((m) => m.type === "roomOpened" || m.type === "error", "roomOpened")).payload;
if (!opened.code) throw new Error(`host refused: ${JSON.stringify(opened)}`);
step(`room opened with a Game PIN (grace period ${opened.gracePeriod}s)`);
host.send({ type: "updateTeams", payload: { teams: [{ id: teamID, name: "Smoke", color: "#FF8800", claimed: false }] } });

// 2. A phone gets the page and joins with the PIN.
const page = await fetch(`${base.replace(/\/$/, "")}/?code=${opened.code}`);
if (!page.ok || !(await page.text()).includes("PROTOCOL_VERSION")) throw new Error("buzzer page not served");
step("buzzer page served");
const phone = client("/ws", "phone");
await phone.opened;
phone.send({ type: "join", code: opened.code, version: 10, device: "smoke-test-device" });
await phone.waitFor((m) => m.type === "joinAccepted", "joinAccepted");
phone.send({ type: "claim", teamID });
await phone.waitFor((m) => m.type === "claimAccepted", "claimAccepted");
await host.waitFor((m) => m.type === "claimedTeams" && m.payload.teamIDs.includes(teamID), "claimedTeams");
step("phone joined with the PIN and claimed a team; host told");

// 3. Play: arm, buzz, host sees who buzzed first.
host.send({ type: "setBuzzerMode", payload: { mode: "armed" } });
await phone.waitFor((m) => m.type === "buzzerState" && m.payload.state === "armed", "armed");
phone.send({ type: "buzz" });
await host.waitFor((m) => m.type === "firstBuzz" && m.payload?.teamID === teamID, "firstBuzz");
await phone.waitFor((m) => m.type === "buzzerState" && m.payload.state === "first", "first");
step("phone buzzed; host saw the first buzz");

// 4. Host drops; phone sees the buzzer unavailable.
host.send({ type: "setBuzzerMode", payload: { mode: "armed" } });
host.close();
await host.closed;
await phone.waitFor((m) => m.type === "buzzerState" && m.payload.state === "unavailable", "unavailable while the host is away");
step("host dropped; phone shows the buzzer as unavailable");

// 5. Host resumes with its token; phone is back.
phone.messages.length = 0;
const back = client("/host", "host (resumed)");
await back.opened;
back.send({ type: "hello", payload: { token, version: 1, resumeToken: opened.resumeToken, client: "smoke-test" } });
const resumed = (await back.waitFor((m) => m.type === "roomOpened" || m.type === "error", "roomOpened (resumed)")).payload;
if (!resumed.resumed || resumed.code !== opened.code) throw new Error(`resume failed: ${JSON.stringify(resumed)}`);
await phone.waitFor((m) => m.type === "buzzerState" && m.payload.state === "armed", "armed after resume");
step("host resumed the same room; phone's buzzer is back");

// 6. Wrong token and wrong PIN are refused.
const intruder = client("/host", "intruder");
await intruder.opened;
intruder.send({ type: "hello", payload: { token: "x".repeat(token.length), version: 1 } });
await intruder.waitFor((m) => m.type === "error" && m.payload.code === "badToken", "badToken");
const stranger = client("/ws", "stranger");
await stranger.opened;
stranger.send({ type: "join", code: "ZZZZZZ", version: 10 });
await stranger.waitFor((m) => m.type === "joinRejected", "joinRejected");
step("wrong host token and wrong PIN refused");

// 7. Host ends the game; phone is told.
back.send({ type: "closeRoom" });
await back.waitFor((m) => m.type === "roomClosed", "roomClosed");
await phone.waitFor((m) => m.type === "sessionEnded", "sessionEnded");
step("host closed the room; phone got sessionEnded");

console.log("Smoke test passed.");
process.exit(0);
