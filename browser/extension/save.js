// stash: the "save this login?" prompt, shown in a frame of stash's own
// after you sign in. Only a click here saves anything.

"use strict";

const token = decodeURIComponent(location.hash.slice(1));
const title = document.getElementById("title");
const detail = document.getElementById("detail");
const yes = document.getElementById("yes");
const no = document.getElementById("no");
const send = (message) => chrome.runtime.sendMessage({ ...message, token });

let info = null;

async function load() {
  info = await send({ type: "save-info" });
  if (!info.ok) return send({ type: "save-dismiss" });
  const who = info.username ? info.username : t("thisLogin");
  if (info.kind === "card") {
    title.textContent = t("saveThisCard");
    detail.textContent = t("saveCardDetail", info.summary, info.host);
  } else if (info.state === "changed") {
    title.textContent = t("updatePassword", info.host);
    detail.textContent = t("updatePasswordDetail", who);
    yes.textContent = t("update");
  } else {
    title.textContent = t("saveLoginFor", info.host);
    detail.textContent = info.username ? t("loginForUsername", info.username) : t("withoutUsername");
  }
  yes.focus();
}

yes.addEventListener("click", async (event) => {
  if (!event.isTrusted) return;
  yes.disabled = no.disabled = true;
  yes.textContent = info?.kind === "card" ? t("waitingTouchId") : t("saving");
  const reply = await send({ type: "save-confirm" });
  if (reply.ok) {
    title.textContent = reply.action === "unchanged" ? t("alreadySaved") : t("saved");
    detail.textContent = reply.name ? t("savedAs", reply.name) : "";
  } else {
    title.textContent = t("notSaved");
    detail.textContent = localizedError(reply.error);
  }
  document.querySelector(".actions").hidden = true;
  setTimeout(() => send({ type: "save-dismiss" }), 1800);
});

no.addEventListener("click", () => send({ type: "save-dismiss" }));
document.addEventListener("keydown", (e) => e.key === "Escape" && send({ type: "save-dismiss" }));

load().catch(() => send({ type: "save-dismiss" }));
