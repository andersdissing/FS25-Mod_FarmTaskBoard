"""Static checks for the mod in Build/:
- XML is well-formed
- Lua parses, and uses nothing newer than Lua 5.1 (the game's Lua): no goto, no //, no table.unpack
- every l10n key used in Lua exists in translations/l10n_en.xml, _de.xml, _fr.xml and _da.xml
- all languages have the same placeholders (%d, %s) in the same order, and start with a capital
- title and description in modDesc in every language; German description not a copy of English

Usage: python tests/check_static.py [mod_dir]      (default: Build)
Needs: pip install luaparser
"""
import glob
import re
import struct
import sys
import xml.etree.ElementTree as ET

from luaparser import ast

root = sys.argv[1] if len(sys.argv) > 1 else "Build"
ok = True


def fail(*args):
    global ok
    ok = False
    print(*args)


for f in glob.glob(root + "/**/*.xml", recursive=True):
    try:
        ET.parse(f)
    except Exception as e:
        fail("XML FAIL", f, e)

desc = ET.parse(root + "/modDesc.xml").getroot()
# Base game keys the mod uses
BASE_KEYS = {"ui_ingameMenuPrev", "ui_ingameMenuNext"}
# Key prefixes built at runtime: prefix + value
PREFIXES = ("ftb_status_",)

# ModHub: every UI text needs at least EN and DE (guideline 8.2); we also ship FR and DA.
# Texts are in <prefix>_<lang>.xml (modDesc <l10n filenamePrefix>); every file has the same keys.
# Texts must start with a capital letter (guideline 5.5); a placeholder or "+"/"\"" start is fine.
LANGUAGES = ("en", "de", "da", "fr")
l10n = desc.find("l10n")
prefix = l10n.get("filenamePrefix") if l10n is not None else None
if prefix is None:
    fail("modDesc has no <l10n filenamePrefix>")
    prefix = "translations/l10n"
tables = {}
for lang in LANGUAGES:
    path = f"{root}/{prefix}_{lang}.xml"
    try:
        tables[lang] = {t.get("name"): t.get("text") for t in ET.parse(path).getroot().iter("text")}
    except Exception as e:
        fail("MISSING translation file", path, e)
        tables[lang] = {}
texts = tables["en"]

placeholder = re.compile(r"%[ds]")
for lang in LANGUAGES[1:]:
    for name in sorted(set(texts) - set(tables[lang])):
        fail("MISSING", lang, "for l10n", name)
    for name in sorted(set(tables[lang]) - set(texts)):
        fail("EXTRA key only in", lang, name)
for name, en in texts.items():
    en_ph = placeholder.findall(en or "")
    for lang in LANGUAGES:
        value = tables[lang].get(name)
        if value is None:
            continue
        if not value.strip():
            fail("EMPTY", lang, name)
            continue
        if placeholder.findall(value) != en_ph:
            fail("PLACEHOLDERS differ en/" + lang, name, en_ph, placeholder.findall(value))
        first = value.lstrip()[:1]
        if first.isalpha() and first != first.upper():
            fail("LOWER-CASE START", lang, name, value[:40])

# The ModHub upload form also needs French title and description
for part in ("title", "description"):
    element = desc.find(part)
    for lang in LANGUAGES:
        if element is None or element.find(lang) is None or not (element.find(lang).text or "").strip():
            fail("MISSING", lang, "in modDesc", part)
    if element is not None and element.find("de") is not None and element.find("en") is not None \
            and element.find("de").text == element.find("en").text and part == "description":
        fail("German description is a copy of the English one")

used = set()
for f in glob.glob(root + "/scripts/*.lua"):
    src = open(f, encoding="utf-8").read()
    try:
        ast.parse(src)
    except Exception as e:
        fail("LUA FAIL", f, str(e)[:300])
    code = re.sub(r"--[^\n]*", "", src)
    for pattern, what in ((r"\bgoto\b", "goto"), (r"//", "integer division //"), (r"table\.unpack", "table.unpack")):
        if re.search(pattern, code):
            fail("LUA 5.1", f, "uses", what)
    # TestRunner PublicLuaCheck warns about lines of 200 characters or more ([Long-Line])
    for n, line in enumerate(src.splitlines(), 1):
        if len(line) >= 200:
            fail("TESTRUNNER", f, f"line {n} has {len(line)} characters (Long-Line warning at 200)")
    # The ModHub TestRunner (PublicLuaCheck) fails a mod that uses pcall/xpcall: they hide errors from the log
    if re.search(r"\bx?pcall\s*\(", code):
        fail("TESTRUNNER", f, "uses pcall/xpcall")
    for key in re.findall(r'\b(?:t|tf|getText)\("([A-Za-z_]+)"', src):
        used.add((f, key))
    for key in re.findall(r'"(ftb_[A-Za-z_]+)"', src):
        used.add((f, key))

for f, key in sorted(used):
    if key in texts or key in BASE_KEYS or key in PREFIXES:
        continue
    fail("MISSING l10n", f, key)

for prefix in PREFIXES:
    if not any(name.startswith(prefix) for name in texts):
        fail("MISSING l10n prefix", prefix)

# Mod icon: the TestRunner (ModDescCheck) wants 512x512; guideline 5.1: BC1 (DXT1) without mipmaps
icon = desc.findtext("iconFilename")
try:
    head = open(f"{root}/{icon}", "rb").read(128)
    height, width = struct.unpack("<II", head[12:20])
    mips = struct.unpack("<I", head[28:32])[0]
    if (width, height) != (512, 512) or head[84:88] != b"DXT1" or mips > 1:
        fail("MOD ICON", icon, f"{width}x{height}", head[84:88], f"mipmaps {mips}", "(want 512x512 DXT1, no mipmaps)")
except OSError as e:
    fail("MOD ICON", icon, e)

# Titles: every word starts with a capital letter (TestRunner ModDescCheck)
title = desc.find("title")
for lang_element in list(title) if title is not None else []:
    for word in (lang_element.text or "").split():
        if word[:1].isalpha() and word[:1] != word[:1].upper():
            fail("TITLE", lang_element.tag, f"'{lang_element.text}': '{word}' does not start with a capital letter")

print("OK" if ok else "FAILED")
sys.exit(0 if ok else 1)
