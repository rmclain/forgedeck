// Draws the callout leaders once, strikes the first mode of each list forward, and points Download at the newest zip.
(() => {
  const root = document.documentElement;
  root.classList.add("js");
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const spec = document.getElementById("specimen");
  if (reduced || !("IntersectionObserver" in window)) {
    root.classList.add("drawn");
  } else if (spec) {
    const seen = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) { root.classList.add("drawn"); seen.disconnect(); }
    }, { threshold: 0.3 });
    seen.observe(spec);
    setTimeout(() => root.classList.add("drawn"), 2500);
  }

  document.querySelectorAll(".modes").forEach((list) => list.querySelector(".mode")?.classList.add("on"));

  // The newest release's zip and version. The links already work without this.
  fetch("https://api.github.com/repos/rmclain/forgedeck/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? r.json() : null))
    .then((release) => {
      if (!release || !release.tag_name) return;
      const version = release.tag_name.replace(/^v/i, "");
      const zip = (release.assets || []).find((a) => /^forgedeck.*\.zip$/i.test(a.name));
      document.querySelectorAll("[data-version]").forEach((el) => { el.textContent = version; });
      document.querySelectorAll("[data-version-label]").forEach((el) => { el.textContent = "ForgeDeck " + version; });
      if (zip && /^https:\/\/github\.com\//.test(zip.browser_download_url)) {
        document.querySelectorAll("a[data-download]").forEach((a) => { a.href = zip.browser_download_url; });
      }
    })
    .catch(() => {});
})();
