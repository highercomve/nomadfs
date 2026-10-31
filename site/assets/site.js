// The mobile menu, copy buttons on code blocks and the active nav link.
(function () {
  function copied(btn) {
    btn.textContent = "Copied";
    btn.classList.add("copied");
    setTimeout(function () { btn.textContent = "Copy"; btn.classList.remove("copied"); }, 1500);
  }
  // The clipboard API needs HTTPS; elsewhere, a selection and the copy command.
  function copyText(btn, text) {
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () { copied(btn); });
      return;
    }
    var area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    var ok = false;
    try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
    document.body.removeChild(area);
    if (ok) copied(btn);
  }
  // A copy button placed in the markup copies its figure's code.
  document.querySelectorAll("[data-copy]").forEach(function (btn) {
    var code = btn.closest("figure").querySelector("code");
    btn.addEventListener("click", function () { copyText(btn, code.innerText.trim()); });
  });
  document.querySelectorAll(".prose pre").forEach(function (pre) {
    var code = pre.querySelector("code");
    if (!code) return;
    var btn = document.createElement("button");
    btn.className = "copy-btn";
    btn.type = "button";
    btn.textContent = "Copy";
    btn.addEventListener("click", function () { copyText(btn, code.innerText.trim()); });
    pre.appendChild(btn);
  });

  var toggle = document.querySelector(".menu-toggle");
  var nav = document.querySelector(".topnav");
  if (toggle && nav) {
    toggle.addEventListener("click", function () {
      var open = nav.classList.toggle("open");
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
  }
  var here = location.pathname.replace(/index\.html$/, "");
  document.querySelectorAll(".sidebar a, .topnav a").forEach(function (a) {
    var url = new URL(a.href, location.href);
    if (url.hash) return; // a section of a page, not the page
    var p = url.pathname.replace(/index\.html$/, "");
    if (p === here) a.classList.add("active");
  });
})();
