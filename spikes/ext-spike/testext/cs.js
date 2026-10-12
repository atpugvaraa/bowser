document.documentElement.setAttribute("data-ext", "content-script-ran");
chrome.runtime.sendMessage("hi").then(r => document.documentElement.setAttribute("data-bg", JSON.stringify(r))).catch(e => document.documentElement.setAttribute("data-bg", "ERR " + e));
