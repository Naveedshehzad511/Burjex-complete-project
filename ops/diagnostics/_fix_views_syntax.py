from pathlib import Path
import re, py_compile
p = Path('/app/user_portal/views.py')
text = p.read_text(encoding='utf-8', errors='replace')
orig = text
text = re.sub(r'\neholder_page\(request, title: str\):\n    return render\(request, "user_portal/placeholder\.html", \{"title": title\}\)\s*$', '\n', text)
helper = "\ndef _display_open_account_type_name(raw: str | None) -> str:\n    import re\n    name = (raw or '').strip()\n    if not name:\n        return name\n    name = re.sub(r'\\s*\\((?:b[\\s-]?trader|mt5|mt4|match[\\s-]?trader)\\)\\s*', '', name, flags=re.IGNORECASE)\n    name = re.sub(r'\\s*[-\\u2013\\u2014]\\s*(?:b[\\s-]?trader|mt5|mt4)\\s*$', '', name, flags=re.IGNORECASE)\n    return name.strip() or (raw or '').strip()\n\n"
if 'def _display_open_account_type_name' not in text:
    idx = text.find('def _open_account_type_payload(')
    if idx < 0:
        raise SystemExit('anchor missing')
    text = text[:idx] + helper + text[idx:]
text, n = re.subn(r'("name"\s*:\s*)t\.account_name\b', r'\1_display_open_account_type_name(t.account_name)', text, count=1)
if text != orig:
    p.write_text(text, encoding='utf-8')
    print('PATCHED', len(text), 'name_subs', n)
else:
    print('NO_CHANGE')
py_compile.compile(str(p), doraise=True)
print('COMPILE_OK', p.stat().st_size)
