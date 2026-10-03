#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Render captured `ley` output as an HTML block, colours and all, for reviewing a view without a terminal.

    COLORTERM=truecolor LANG=C.UTF-8 ley levels 146.52 --color always --width 100 > levels.txt
    scripts/ansi2html.py "ley levels" < levels.txt > levels.html

Understands the escapes `ley` emits: the 16 ANSI colours, bold, dim, and the truecolor and 256-colour
forms of the level ramp. Output is one <h2> and one <pre class="term">; wrap it in your own page and give
`pre.term` a dark ground and a tight line-height so block glyphs tile. Live views written to a pipe print
every frame in full, so take the last frame (the lines from the last header line down) before converting.

    scripts/ansi2html.py --palette site < pane.txt > pane.html

is the form `leyshots` uses for the site's terminal shots (docs/plans/site-shots.md, "Terminal shots"):
no <h2>, ANSI green drawn in the site's green, and bold text without a colour of its own drawn in the
site's bold colour. The page around it sets the ground and the default foreground.
"""
import html, re, sys
SGR = re.compile(r'\x1b\[([0-9;]*)m')
CSI_OTHER = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]')
BASE16 = ['#3b3b3b','#d54e53','#7bb75c','#e5b567','#5a8dd6','#b47ed6','#5fb3c4','#c9c9c9',
          '#7a7a7a','#ff6b6b','#a5e07a','#ffd56b','#7fb2ff','#d29bff','#8fe2f0','#ffffff']
# The site's terminal theme overrides these entries of BASE16, and gives bold text with no colour of its
# own a colour. Background and foreground are the page's.
SITE = {'green': '#2FB6A3', 'bold': '#E7E9EA'}
def render(text, title, palette='default'):
    base = list(BASE16)
    if palette == 'site':
        base[2] = base[10] = SITE['green']
    out = [] if palette == 'site' else ['<h2>%s</h2>' % html.escape(title)]
    out.append('<pre class="term">')
    state = {'fg': None, 'bold': False, 'dim': False}
    open_span = False
    def style():
        css = []
        fg = state['fg']
        if fg is None and state['bold'] and palette == 'site':
            fg = SITE['bold']
        if fg: css.append('color:%s' % fg)
        if state['bold']: css.append('font-weight:bold')
        if state['dim']: css.append('opacity:.55')
        return ';'.join(css)
    pos = 0
    text = CSI_OTHER.sub(lambda m: m.group(0) if m.group(0).endswith('m') else '', text)
    for m in SGR.finditer(text):
        chunk = text[pos:m.start()]
        if chunk:
            out.append(html.escape(chunk))
        pos = m.end()
        codes = [int(c) if c else 0 for c in m.group(1).split(';')] if m.group(1) else [0]
        i = 0
        while i < len(codes):
            c = codes[i]
            if c == 0: state.update(fg=None, bold=False, dim=False)
            elif c == 1: state['bold'] = True
            elif c == 2: state['dim'] = True
            elif c == 22: state['bold'] = state['dim'] = False
            elif c == 39: state['fg'] = None
            elif 30 <= c <= 37: state['fg'] = base[c - 30]
            elif 90 <= c <= 97: state['fg'] = base[c - 90 + 8]
            elif c == 38 and i + 1 < len(codes):
                if codes[i+1] == 2 and i + 4 < len(codes):
                    state['fg'] = '#%02x%02x%02x' % tuple(codes[i+2:i+5]); i += 4
                elif codes[i+1] == 5 and i + 2 < len(codes):
                    n = codes[i+2]; i += 2
                    if n < 16: state['fg'] = base[n]
                    elif n < 232:
                        n -= 16; r, g, b = n // 36, (n // 6) % 6, n % 6
                        state['fg'] = '#%02x%02x%02x' % tuple(0 if v == 0 else 55 + 40 * v for v in (r, g, b))
                    else:
                        v = 8 + 10 * (n - 232); state['fg'] = '#%02x%02x%02x' % (v, v, v)
            i += 1
        if open_span: out.append('</span>')
        s = style()
        out.append('<span style="%s">' % s if s else '<span>')
        open_span = True
    out.append(html.escape(text[pos:]))
    if open_span: out.append('</span>')
    out.append('</pre>')
    return ''.join(out)
if __name__ == '__main__':
    args = sys.argv[1:]
    palette = 'default'
    if len(args) >= 2 and args[0] == '--palette':
        palette = args[1]
        args = args[2:]
        if palette not in ('default', 'site'):
            sys.exit('ansi2html: --palette is default or site')
    sys.stdout.write(render(sys.stdin.read(), args[0] if args else 'ley', palette))
