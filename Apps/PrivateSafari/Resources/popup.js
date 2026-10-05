"use strict";

// Invoked only by the explicit Connect button. Isolated-world script, top frame
// only, exact HTTPS origin, normal same-origin fetch, no integrity bypass.
async function readOwnSession() {
  if (location.origin !== "https://chatgpt.com") return {error: "wrong_site"};
  try {
    const response = await fetch("https://chatgpt.com/api/auth/session", {
      credentials: "same-origin", cache: "no-store", redirect: "error",
      headers: {Accept: "application/json"}, signal: AbortSignal.timeout(15000)
    });
    if (!response.ok || response.url !== "https://chatgpt.com/api/auth/session") return {error: "sign_in_first"};
    const session = await response.json();
    const token = session.accessToken;
    if (session.error || session.workspaceTokenExchangeError || typeof token !== "string" || token.length < 1 || token.length > 60000 || /\s/.test(token)) return {error: "sign_in_first"};
    const parts = token.split(".");
    if (parts.length !== 3) return {error: "unsupported_session"};
    const segment = parts[1].replaceAll("-", "+").replaceAll("_", "/");
    const claims = JSON.parse(atob(segment + "=".repeat((4 - segment.length % 4) % 4)));
    const auth = claims["https://api.openai.com/auth"];
    const account = auth?.chatgpt_account_id ?? auth?.account_id;
    if (typeof account !== "string" || account.length < 1 || account.length > 128 || /[\r\n]/.test(account)) return {error: "unsupported_session"};
    if (typeof claims.exp !== "number" || !Number.isFinite(claims.exp) || claims.exp * 1000 <= Date.now()) return {error: "sign_in_first"};
    // Claims only select the account header. The native extension verifies this
    // bearer with the real Dot service before staging anything.
    return {credentials: {access_token: token, account_id: account}};
  } catch { return {error: "sign_in_first"}; }
}

const connect = document.getElementById("connect");
const status = document.getElementById("status");
const returnLink = document.getElementById("return");
const messages = {
  wrong_site: "Open chatgpt.com in this Safari tab, sign in as yourself, then try again.",
  sign_in_first: "Sign in to ChatGPT in this Safari tab, then try again.",
  unsupported_session: "This browser session format is not supported by the private setup yet.",
  sign_out_first: "Sign out in the Dot app before connecting a different account.",
  access_unavailable: "This browser sign-in could not reach your existing Dot. No sign-in was saved.",
  invalid_session: "The sign-in could not be transferred. Please try again."
};

connect.addEventListener("click", async () => {
  connect.disabled = true;
  status.textContent = "Checking your signed-in account…";
  try {
    const [tab] = await browser.tabs.query({active: true, currentWindow: true});
    if (!tab || new URL(tab.url).origin !== "https://chatgpt.com") throw {code: "wrong_site"};
    const results = await browser.scripting.executeScript({target: {tabId: tab.id, frameIds: [0]}, func: readOwnSession, world: "ISOLATED"});
    const result = results?.[0]?.result;
    if (!result?.credentials) throw {code: result?.error ?? "invalid_session"};
    status.textContent = "Checking access to your Dot…";
    const response = await browser.runtime.sendNativeMessage("dev.dotwatch.app", {operation: "connect", credentials: result.credentials});
    // Never put the token in a URL, DOM, console, storage API or error message.
    if (response?.ok !== true) throw {code: response?.code ?? "invalid_session"};
    status.textContent = "Ready. Return to Dot to save this sign-in in Keychain and see your character.";
    returnLink.hidden = false;
  } catch (error) {
    status.textContent = messages[error?.code] ?? "Private setup could not finish. Please try again.";
    connect.disabled = false;
  }
});
