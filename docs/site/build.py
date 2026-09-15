#!/usr/bin/env python3
"""PoiBuilder docs builder. Stdlib only. Deterministic output."""
from __future__ import annotations

import argparse
import hashlib
import html
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
PAGES = ROOT / "pages"
NAV_FILE = ROOT / "nav.txt"
TEMPLATE = ROOT / "template.html"
OUT = ROOT / "out"
ASSETS = ROOT / "assets"
PLUGIN_CFG = REPO / "project" / "addons" / "poibuilder" / "plugin.cfg"
ACTIONS_GD = REPO / "project" / "addons" / "poibuilder" / "editor" / "pb_actions.gd"
FONT_SRC = REPO / "showcase_video" / "fonts"
ADDON_BUNDLE = REPO / "project" / "addons" / "poibuilder" / "docs-site"

KEY_NAMES = {
    "KEY_H": "H", "KEY_J": "J", "KEY_K": "K", "KEY_X": "X", "KEY_Y": "Y",
    "KEY_G": "G", "KEY_I": "I", "KEY_C": "C", "KEY_L": "L", "KEY_R": "R",
    "KEY_E": "E", "KEY_B": "B", "KEY_6": "6", "KEY_EQUAL": "=", "KEY_MINUS": "-",
    "KEY_BRACKETRIGHT": "]", "KEY_BRACKETLEFT": "[", "KEY_BACKSLASH": "\\",
}


def plugin_version() -> str:
    text = PLUGIN_CFG.read_text(encoding="utf-8")
    m = re.search(r'^version="([^"]+)"', text, re.M)
    if not m:
        raise SystemExit("plugin.cfg has no version")
    return m.group(1)


def parse_front(text: str) -> tuple[dict, str]:
    meta: dict = {}
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            block = text[4:end]
            body = text[end + 5:]
            for line in block.splitlines():
                if ":" in line:
                    k, v = line.split(":", 1)
                    meta[k.strip()] = v.strip().strip('"')
            return meta, body
    return meta, text


def inline(s: str) -> str:
    s = html.escape(s)
    s = re.sub(r"`([^`]+)`", lambda m: f"<code>{m.group(1)}</code>", s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)", r"<em>\1</em>", s)
    s = re.sub(
        r"!\[([^\]]*)\]\(([^)]+)\)",
        lambda m: f'<img src="{m.group(2)}" alt="{m.group(1)}">',
        s,
    )
    s = re.sub(
        r"\[([^\]]+)\]\(([^)]+)\)",
        lambda m: f'<a href="{m.group(2)}">{m.group(1)}</a>',
        s,
    )
    s = re.sub(r"\[\[kbd:([^\]]+)\]\]", lambda m: "".join(
        f"<kbd>{html.escape(p.strip())}</kbd>" for p in m.group(1).split("+")
    ), s)
    return s


def is_pot_image_missing(src: str, out_dir: Path) -> bool:
    if src.startswith(("http://", "https://", "data:")):
        return False
    return not (out_dir / src).is_file() and not (ASSETS / src).is_file() and not (ASSETS / Path(src).name).is_file()


def render_md(src: str, out_dir: Path, strict: bool) -> str:
    lines = src.replace("\r\n", "\n").split("\n")
    out: list[str] = []
    i = 0
    in_html = 0

    def flush_para(buf: list[str]) -> None:
        if buf:
            out.append("<p>" + inline(" ".join(buf)) + "</p>")
            buf.clear()

    para: list[str] = []
    while i < len(lines):
        line = lines[i]
        if line.strip() == "<!-- KEYS_TABLE -->":
            flush_para(para)
            out.append(keys_table())
            i += 1
            continue
        if line.strip().startswith("<") and not line.strip().startswith("</"):
            flush_para(para)
            chunk = [line]
            tag = re.match(r"</?([a-zA-Z0-9]+)", line.strip())
            name = tag.group(1) if tag else ""
            if name in {"div", "figure", "section", "video", "ol", "ul", "blockquote"} and f"</{name}>" not in line:
                i += 1
                while i < len(lines) and f"</{name}>" not in lines[i]:
                    chunk.append(lines[i])
                    i += 1
                if i < len(lines):
                    chunk.append(lines[i])
            out.append("\n".join(chunk))
            i += 1
            continue
        if line.startswith("```"):
            flush_para(para)
            lang = html.escape(line[3:].strip())
            i += 1
            body: list[str] = []
            while i < len(lines) and not lines[i].startswith("```"):
                body.append(lines[i])
                i += 1
            out.append(f'<pre><code class="lang-{lang}">' + html.escape("\n".join(body)) + "</code></pre>")
            i += 1
            continue
        if re.match(r"^:::video\s+", line):
            flush_para(para)
            path = line.split(None, 1)[1].strip()
            cap = ""
            i += 1
            while i < len(lines) and lines[i].strip() != ":::":
                cap += lines[i] + " "
                i += 1
            missing = is_pot_image_missing(path, out_dir)
            if missing:
                if strict:
                    raise SystemExit(f"missing video {path}")
                out.append(f'<figure><div class="placeholder">Clip not built yet — run ./docs/site/build.sh --assets</div><figcaption>{inline(cap.strip())}</figcaption></figure>')
            else:
                out.append(
                    f'<figure><video class="shot" autoplay loop muted playsinline controls src="{html.escape(path)}"></video>'
                    f"<figcaption>{inline(cap.strip())}</figcaption></figure>"
                )
            i += 1
            continue
        if re.match(r"^:::shot\s+", line):
            flush_para(para)
            path = line.split(None, 1)[1].strip()
            cap = ""
            i += 1
            while i < len(lines) and lines[i].strip() != ":::":
                cap += lines[i] + " "
                i += 1
            missing = is_pot_image_missing(path, out_dir)
            if missing:
                if strict:
                    raise SystemExit(f"missing image {path}")
                out.append(f'<figure><div class="placeholder">Screenshot not built yet — run ./docs/site/build.sh --assets</div><figcaption>{inline(cap.strip())}</figcaption></figure>')
            else:
                out.append(
                    f'<figure><img class="shot" src="{html.escape(path)}" alt="{html.escape(cap.strip())}">'
                    f"<figcaption>{inline(cap.strip())}</figcaption></figure>"
                )
            i += 1
            continue
        if line.strip() == "<!-- KEYS_TABLE -->":
            flush_para(para)
            out.append(keys_table())
            i += 1
            continue
        if line.startswith("|") and i + 1 < len(lines) and re.match(r"^\|?\s*-+", lines[i + 1]):
            flush_para(para)
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append([c.strip() for c in lines[i].strip("|").split("|")])
                i += 1
            # drop align row
            head, body = rows[0], rows[2:] if len(rows) > 2 else []
            html_rows = ["<table><thead><tr>" + "".join(f"<th>{inline(c)}</th>" for c in head) + "</tr></thead><tbody>"]
            for r in body:
                html_rows.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>")
            html_rows.append("</tbody></table>")
            out.append("".join(html_rows))
            continue
        m = re.match(r"^(#{1,4})\s+(.*)$", line)
        if m:
            flush_para(para)
            lvl = len(m.group(1))
            title = m.group(2).strip()
            slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
            out.append(f'<h{lvl} id="{slug}">{inline(title)}</h{lvl}>')
            i += 1
            continue
        if line.strip() in {"---", "***"}:
            flush_para(para)
            out.append("<hr>")
            i += 1
            continue
        if line.startswith("> "):
            flush_para(para)
            kind = ""
            buf = []
            while i < len(lines) and lines[i].startswith("> "):
                t = lines[i][2:]
                if t.startswith("[gotcha]"):
                    kind = " gotcha"
                    t = t[len("[gotcha]"):].strip()
                elif t.startswith("[limit]"):
                    kind = " limit"
                    t = t[len("[limit]"):].strip()
                buf.append(t)
                i += 1
            out.append(f'<blockquote class="{kind.strip()}">{inline(" ".join(buf))}</blockquote>')
            continue
        if re.match(r"^[-*]\s+", line) or re.match(r"^\d+\.\s+", line):
            flush_para(para)
            ordered = bool(re.match(r"^\d+\.\s+", line))
            cls = "steps" if ordered else ""
            tag = "ol" if ordered else "ul"
            items = []
            while i < len(lines) and (re.match(r"^[-*]\s+", lines[i]) or re.match(r"^\d+\.\s+", lines[i])):
                items.append(re.sub(r"^([-*]|\d+\.)\s+", "", lines[i]))
                i += 1
            cls_attr = f' class="{cls}"' if cls else ""
            out.append(f"<{tag}{cls_attr}>" + "".join(f"<li>{inline(it)}</li>" for it in items) + f"</{tag}>")
            continue
        if not line.strip():
            flush_para(para)
            i += 1
            continue
        para.append(line.strip())
        i += 1
    flush_para(para)
    return "\n".join(out)


def parse_nav() -> list[tuple[str | None, str | None, str]]:
    """Return list of (file_stem or None, href or None, title). Section headers have no href."""
    items = []
    for raw in NAV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.endswith(".md") or ".md " in line:
            path, title = line.split(None, 1)
            stem = Path(path).stem
            items.append((stem, f"{stem}.html", title))
        else:
            items.append((None, None, line))
    return items


def nav_html(current: str) -> str:
    chunks = []
    open_group = False
    for stem, href, title in parse_nav():
        if href is None:
            if open_group:
                chunks.append("</div>")
            chunks.append(f'<div class="group"><div class="group-title">{html.escape(title)}</div>')
            open_group = True
            continue
        cur = ' class="current"' if stem == current else ""
        chunks.append(f'<a href="{href}"{cur}>{html.escape(title)}</a>')
    if open_group:
        chunks.append("</div>")
    return "\n".join(chunks)


def page_sequence() -> list[tuple[str, str]]:
    return [(stem, title) for stem, href, title in parse_nav() if href]


def pager(stem: str) -> str:
    seq = page_sequence()
    idx = next((i for i, (s, _) in enumerate(seq) if s == stem), None)
    if idx is None:
        return ""
    prev_h = next_h = ""
    if idx > 0:
        s, t = seq[idx - 1]
        prev_h = f'<a href="{s}.html"><span class="dir">Previous</span>{html.escape(t)}</a>'
    else:
        prev_h = "<span></span>"
    if idx + 1 < len(seq):
        s, t = seq[idx + 1]
        next_h = f'<a href="{s}.html"><span class="dir">Next</span>{html.escape(t)}</a>'
    return prev_h + next_h


def keys_table() -> str:
    text = ACTIONS_GD.read_text(encoding="utf-8")
    rows = []
    for m in re.finditer(
        r'"([^"]+)":\s*\{\s*"label":\s*"([^"]+)",\s*"keys":\s*(\[\[.*?\]\]|\[\])',
        text,
        re.S,
    ):
        aid, label, keys = m.group(1), m.group(2), m.group(3)
        if keys.strip() == "[]":
            shortcut = "—"
        else:
            parts = []
            for spec in re.finditer(r"\[(KEY_[A-Z0-9]+),\s*(\d),\s*(\d),\s*(\d)\]", keys):
                name, ctrl, shift, alt = spec.group(1), spec.group(2), spec.group(3), spec.group(4)
                chord = []
                if ctrl == "1":
                    chord.append("Ctrl")
                if shift == "1":
                    chord.append("Shift")
                if alt == "1":
                    chord.append("Alt")
                chord.append(KEY_NAMES.get(name, name.replace("KEY_", "")))
                parts.append("+".join(chord))
            shortcut = " or ".join(parts) if parts else "—"
        if shortcut == "—":
            kbd = "—"
        else:
            kbd = " ".join(
                "".join(f"<kbd>{html.escape(x)}</kbd>" for x in ch.split("+"))
                for ch in shortcut.split(" or ")
            )
        rows.append((label, kbd, aid))
    body = "".join(
        f"<tr><td>{html.escape(label)}</td><td>{kbd}</td><td><code>{html.escape(aid)}</code></td></tr>"
        for label, kbd, aid in rows
    )
    return (
        "<table><thead><tr><th>Action</th><th>Default</th><th>Id</th></tr></thead>"
        f"<tbody>{body}</tbody></table>"
    )



def copy_static(out: Path) -> None:
    shutil.copy2(ROOT / "style.css", out / "style.css")
    (out / ".nojekyll").write_text("", encoding="utf-8")
    if (ROOT / "favicon.svg").is_file():
        shutil.copy2(ROOT / "favicon.svg", out / "favicon.svg")
    font_dir = out / "fonts"
    font_dir.mkdir(exist_ok=True)
    src = FONT_SRC / "Inter-Variable.ttf"
    if src.is_file():
        shutil.copy2(src, font_dir / "Inter-Variable.ttf")
        ofl = FONT_SRC / "OFL.txt"
        if ofl.is_file():
            shutil.copy2(ofl, font_dir / "OFL.txt")
    if ASSETS.is_dir():
        for child in sorted(ASSETS.iterdir()):
            dest = out / child.name if child.suffix.lower() in {".png", ".jpg", ".webp", ".svg"} else out / child.name
            if child.is_file():
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(child, out / child.name)
            elif child.is_dir():
                target = out / child.name
                if target.exists():
                    shutil.rmtree(target)
                shutil.copytree(child, target)


def collect_internal_hrefs(html_text: str) -> list[str]:
    return re.findall(r'(?:href|src)="([^"]+)"', html_text)


def link_check(out: Path, strict: bool) -> int:
    broken = 0
    for page in sorted(out.glob("*.html")):
        text = page.read_text(encoding="utf-8")
        for href in collect_internal_hrefs(text):
            if href.startswith(("http://", "https://", "mailto:", "#")):
                continue
            path = href.split("#", 1)[0]
            if not path:
                continue
            target = (page.parent / path).resolve()
            if not target.is_file():
                print(f"BROKEN {page.name} -> {href}")
                broken += 1
    if broken and strict:
        return 1
    print(f"link check: {broken} missing target(s)")
    return 0 if not strict else (1 if broken else 0)


def build(strict: bool = False, bundle: bool = False) -> int:
    version = plugin_version()
    tpl = TEMPLATE.read_text(encoding="utf-8")
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    copy_static(OUT)

    pages = sorted(PAGES.glob("*.md"))
    if not pages:
        raise SystemExit("no pages in docs/site/pages")

    for md in pages:
        meta, body = parse_front(md.read_text(encoding="utf-8"))
        stem = md.stem
        title = meta.get("title") or stem.replace("-", " ").title()
        lead = meta.get("lead", "")
        body_class = "has-hero" if meta.get("hero") == "true" else ""
        hero = ""
        if meta.get("hero") == "true":
            hero = (
                f'<header class="hero"><h1>{html.escape(title)}</h1>'
                f'<p class="lead">{html.escape(lead)}</p>'
                '<div class="hero-actions">'
                '<a class="btn btn-cyan" href="first-minutes.html">Build a cube in 60 seconds</a>'
                '<a class="btn btn-ghost" href="install.html">Install</a>'
                "</div></header>"
            )
            content = render_md(body, OUT, strict)
        else:
            content = f"<h1>{html.escape(title)}</h1>"
            if lead:
                content += f'<p class="lead">{html.escape(lead)}</p>'
            content += render_md(body, OUT, strict)
        html_out = (
            tpl.replace("{{title}}", html.escape(title))
            .replace("{{version}}", html.escape(version))
            .replace("{{lead}}", html.escape(lead or title))
            .replace("{{body_class}}", body_class)
            .replace("{{nav}}", nav_html(stem))
            .replace("{{hero}}", hero)
            .replace("{{content}}", content)
            .replace("{{prev}}", "")  # filled below via pager combined
            .replace("{{next}}", pager(stem))
        )
        (OUT / f"{stem}.html").write_text(html_out, encoding="utf-8", newline="\n")

    rc = link_check(OUT, strict)
    print(f"built {len(list(OUT.glob('*.html')))} pages for PoiBuilder {version} -> {OUT}")
    if bundle:
        if ADDON_BUNDLE.exists():
            shutil.rmtree(ADDON_BUNDLE)
        shutil.copytree(OUT, ADDON_BUNDLE)
        print(f"bundled -> {ADDON_BUNDLE}")
    return rc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--bundle", action="store_true")
    args = ap.parse_args()
    return build(strict=args.strict, bundle=args.bundle)


if __name__ == "__main__":
    sys.exit(main())
