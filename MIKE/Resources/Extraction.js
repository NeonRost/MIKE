// MIKE – Mike's Toolbox
// Copyright (C) 2026 NeonRost
// Licensed under the GNU General Public License v3 or later.
//
// Injected into the loaded page together with Readability.js.
// Returns a JSON string:
//   { ok: true,  text: "…", title: "…" }
//   { ok: false, reason: "no-article" }
//   { ok: false, reason: "exception", detail: "…" }
//
// Failures report a machine-readable reason rather than a sentence, so the
// message the user sees can be translated on the Swift side.

// Structural noise Readability sometimes drags in when it sits close to the
// article text: navigation, breadcrumbs, "related" boxes, video players,
// consent bars and the like. Matched by their DOM role, never by their text.
const REMOVE_BEFORE_EXTRACTION = [
  "nav",
  "header",
  "footer",
  "aside",
  '[role="navigation"]',
  '[role="banner"]',
  '[role="complementary"]',
  '[aria-label="breadcrumb"]',
  '[class*="breadcrumb"]',
  '[class*="navigation"]',
  '[class*="navbar"]',
  '[class*="related"]',
  '[class*="recommendation"]',
  '[class*="teaser-"]',
  '[class*="video-"]',
  '[class*="player"]',
  '[class*="social"]',
  '[class*="share-"]',
  '[class*="cookie"]',
  '[class*="consent"]',
  '[class*="aside"]',
  "figure > figcaption",
];

// Leftover lines Readability keeps as plain text. When a line matches, that
// line and the one directly after it (usually the linked headline of a "read
// also" box) are dropped.
const REMOVE_LINE_PATTERNS = [
  /^lesen\s+sie\s+auch/i,
  /^mehr\s+zum\s+thema/i,
  /^verwandte\s+artikel/i,
  /^related\s*:/i,
  /^read\s+more/i,
  /^also\s+interesting/i,
  /^voir\s+aussi/i,
  /^también\s+te\s+puede/i,
  /^-?\d+:\d+$/, // video timestamps such as "-2:30" or "1:04:22"
  /^pfadnavigation$/i,
];

// Removes the structural noise above, but only where it sits OUTSIDE the
// presumed article region — so nothing inside the actual article text is
// touched. The region is approximated by the usual article containers; if none
// can be found, nothing is removed at all, because "outside" is then undefined
// and eating the article would be worse than keeping some noise.
function __cleanupBeforeExtraction(root) {
  const articleRoot =
    root.querySelector('[itemprop="articleBody"]') ||
    root.querySelector("article") ||
    root.querySelector("main") ||
    root.querySelector('[role="main"]');

  if (!articleRoot) return;

  REMOVE_BEFORE_EXTRACTION.forEach((selector) => {
    let matches;
    try {
      matches = root.querySelectorAll(selector);
    } catch (e) {
      return; // ignore a selector this engine dislikes rather than abort
    }
    matches.forEach((el) => {
      // Keep the article region itself, anything within it, and any ancestor
      // that would take the article down with it.
      if (el === articleRoot || articleRoot.contains(el) || el.contains(articleRoot)) {
        return;
      }
      el.remove();
    });
  });
}

// Drops remnant lines matched by REMOVE_LINE_PATTERNS, together with the line
// immediately following each match. Markdown prefixes (#, -, >) are stripped
// before matching so a heading like "## Lesen Sie auch" is caught too.
function __stripRemnantLines(lines) {
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const probe = lines[i].replace(/^\s*(?:#{1,6}\s+|[-*>]\s+)/, "").trim();
    if (REMOVE_LINE_PATTERNS.some((re) => re.test(probe))) {
      i++; // skip this line and the one directly after it
      continue;
    }
    out.push(lines[i]);
  }
  return out;
}

function __extractArticle(format, sourceLabel) {
  try {
    const clone = document.cloneNode(true);
    __cleanupBeforeExtraction(clone);
    const article = new Readability(clone).parse();

    if (!article || !article.textContent || article.textContent.trim().length < 80) {
      return JSON.stringify({ ok: false, reason: "no-article" });
    }

    const tmp = document.createElement("div");
    tmp.innerHTML = article.content;

    const blocks = tmp.querySelectorAll("h1,h2,h3,h4,h5,h6,p,li,blockquote,figcaption,pre");
    const lines = [];

    blocks.forEach((b) => {
      const tag = b.tagName.toLowerCase();

      // Do not emit nested elements twice
      // (e.g. a <p> inside a <blockquote> or <li>).
      if (tag !== "blockquote" && tag !== "li" && b.parentElement && b.parentElement.closest("blockquote, li")) {
        return;
      }
      if (tag === "li" && b.parentElement && b.parentElement.closest("li")) {
        return;
      }

      const t = b.innerText.replace(/\s+/g, " ").trim();
      if (!t) return;

      if (format === "markdown") {
        if (tag[0] === "h") {
          // One level down, because the article title becomes the H1.
          const level = Math.min(parseInt(tag[1], 10) + 1, 6);
          lines.push("#".repeat(level) + " " + t);
        } else if (tag === "li") {
          lines.push("- " + t);
        } else if (tag === "blockquote") {
          lines.push("> " + t);
        } else if (tag === "figcaption") {
          lines.push("*" + t + "*");
        } else {
          lines.push(t);
        }
      } else {
        lines.push(t);
      }
    });

    const head = [];
    const title = (article.title || document.title || "").trim();
    const byline = (article.byline || "").trim();

    if (format === "markdown") {
      if (title) head.push("# " + title);
      if (byline) head.push("*" + byline + "*");
    } else {
      if (title) head.push(title);
      if (byline) head.push(byline);
    }

    const label = sourceLabel || "Source:";
    const source =
      format === "markdown"
        ? label + " [" + location.hostname + "](" + location.href + ")"
        : label + " " + location.href;

    const separator = format === "markdown" ? "---\n\n" : "";
    const bodyLines = __stripRemnantLines(lines);
    const text =
      head.join("\n\n") + "\n\n" + bodyLines.join("\n\n") + "\n\n" + separator + source + "\n";

    return JSON.stringify({
      ok: true,
      text: text.replace(/\n{3,}/g, "\n\n"),
      title: title,
    });
  } catch (e) {
    return JSON.stringify({ ok: false, reason: "exception", detail: String(e) });
  }
}
