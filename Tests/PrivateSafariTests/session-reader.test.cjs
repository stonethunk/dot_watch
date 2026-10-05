const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const source = fs.readFileSync(path.join(__dirname, "../../Apps/PrivateSafari/Resources/popup.js"), "utf8");

function fixture(overrides = {}) {
  const nodes = Object.fromEntries(["connect", "status", "return"].map(id => [id, {textContent: "", hidden: true, addEventListener: (event, fn) => { nodes[id][event] = fn; }}]));
  const calls = {fetch: [], native: [], inject: []};
  const token = ["fixture", Buffer.from(JSON.stringify({exp: Date.now() / 1000 + 600, "https://api.openai.com/auth": {chatgpt_account_id: "test-account"}})).toString("base64url"), "fixture"].join(".");
  const context = vm.createContext({
    location: {origin: "https://chatgpt.com"}, URL, Date, AbortSignal,
    atob: text => Buffer.from(text, "base64").toString("binary"),
    document: {getElementById: id => nodes[id]},
    fetch: async (url, options) => {
      calls.fetch.push({url, options});
      return {ok: true, url: "https://chatgpt.com/api/auth/session", json: async () => ({accessToken: token, refresh_token: "must-not-transfer", user: {email: "fixture@example.invalid"}})};
    },
    browser: {
      tabs: {query: async () => [{id: 7, url: "https://chatgpt.com/"}]},
      scripting: {executeScript: async options => { calls.inject.push(options); return [{result: await vm.runInContext("readOwnSession()", context)}]; }},
      runtime: {sendNativeMessage: async (name, payload) => { calls.native.push({name, payload}); return {ok: true, code: "ready"}; }}
    },
    ...overrides
  });
  vm.runInContext(source, context);
  return {context, nodes, calls, token, read: () => vm.runInContext("readOwnSession()", context)};
}

test("opening the helper performs no session read or native transfer", () => {
  const f = fixture();
  assert.equal(f.calls.fetch.length, 0);
  assert.equal(f.calls.native.length, 0);
  assert.equal(typeof f.nodes.connect.click, "function");
});
test("another origin is rejected without making a request", async () => {
  const f = fixture({location: {origin: "https://chatgpt.com.attacker.invalid"}});
  assert.equal((await f.read()).error, "wrong_site");
  assert.equal(f.calls.fetch.length, 0);
});
test("own session returns only the access token and account and uses no cache or redirects", async () => {
  const f = fixture(), result = await f.read();
  assert.deepEqual(Object.keys(result.credentials).sort(), ["access_token", "account_id"]);
  assert.equal(result.credentials.access_token, f.token);
  assert.equal(f.calls.fetch[0].url, "https://chatgpt.com/api/auth/session");
  assert.equal(f.calls.fetch[0].options.credentials, "same-origin");
  assert.equal(f.calls.fetch[0].options.cache, "no-store");
  assert.equal(f.calls.fetch[0].options.redirect, "error");
});
test("a rejected or redirected session cannot become credentials", async () => {
  for (const response of [{ok: false, url: "https://chatgpt.com/api/auth/session"}, {ok: true, url: "https://auth.openai.com/"}]) {
    const f = fixture({fetch: async () => ({...response, json: async () => { throw Error("must not read"); }})});
    assert.equal((await f.read()).error, "sign_in_first");
  }
});
test("expired, missing account, malformed and whitespace tokens are rejected", async () => {
  const tokens = [
    "fixture." + Buffer.from(JSON.stringify({exp: 1, "https://api.openai.com/auth": {chatgpt_account_id: "test-account"}})).toString("base64url") + ".fixture",
    "fixture." + Buffer.from(JSON.stringify({exp: Date.now() / 1000 + 600})).toString("base64url") + ".fixture",
    "malformed", "has whitespace"
  ];
  for (const token of tokens) {
    const f = fixture({fetch: async () => ({ok: true, url: "https://chatgpt.com/api/auth/session", json: async () => ({accessToken: token})})});
    assert.equal((await f.read()).credentials, undefined);
  }
});
test("explicit Connect confines injection to the active tab top frame in an isolated world", async () => {
  const f = fixture();
  await f.nodes.connect.click();
  assert.equal(f.calls.inject.length, 1);
  assert.equal(f.calls.inject[0].world, "ISOLATED");
  assert.deepEqual(Array.from(f.calls.inject[0].target.frameIds), [0]);
  assert.equal(f.calls.inject[0].target.tabId, 7);
  assert.equal(f.calls.native.length, 1);
  assert.deepEqual(Object.keys(f.calls.native[0].payload.credentials).sort(), ["access_token", "account_id"]);
  for (const node of Object.values(f.nodes)) assert.ok(!node.textContent.includes(f.token));
  assert.equal(f.nodes.return.hidden, false);
});
test("a wrong active tab cannot trigger native messaging", async () => {
  const f = fixture();
  f.context.browser.tabs.query = async () => [{id: 7, url: "http://chatgpt.com/"}];
  await f.nodes.connect.click();
  assert.equal(f.calls.inject.length, 0);
  assert.equal(f.calls.native.length, 0);
  assert.ok(f.nodes.status.textContent.includes("Open chatgpt.com"));
});
test("unknown native failure payloads never appear in the UI", async () => {
  const f = fixture();
  f.context.browser.runtime.sendNativeMessage = async () => ({ok: false, code: f.token});
  await f.nodes.connect.click();
  assert.equal(f.nodes.status.textContent, "Private setup could not finish. Please try again.");
  assert.equal(f.nodes.connect.disabled, false);
});
