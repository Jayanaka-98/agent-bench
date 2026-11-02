"""Templates: `${name}` is replaced from a context; an unknown `${name}` is left
as it is, so code in a spec is never mangled."""

import re;

glob _VAR: re.Pattern = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}");

def render(text: str, ctx: dict[str, any]) -> str {
    def sub(m: re.Match) -> str {
        k = str(m.group(1));
        return str(ctx[k]) if k in ctx else str(m.group(0));
    }
    return _VAR.sub(sub, text);
}
