"use strict";

function t(key, ...values) {
  return chrome.i18n.getMessage(key, values);
}

function localizedError(error) {
  switch (error) {
    case "cancelled": return t("touchIdCancelled");
    case "stash is locked": return t("locked");
    case "stash can't read this tab": return t("pageUnreadable");
    case "stash only fills web pages": return t("blockedPage");
    case "stash only fills pages loaded over https": return t("requiresHttps");
    case "The page changed before stash could fill it.": return t("pageChanged");
    default: return error;
  }
}

document.documentElement.lang = t("languageTag");
for (const element of document.querySelectorAll("[data-i18n]")) {
  element.textContent = t(element.dataset.i18n);
}
