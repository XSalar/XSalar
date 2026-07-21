#!/usr/bin/env python3
"""Minimal renderer for the SmartDNS templates.

Supports exactly the subset of Jinja used by our templates:
  * {{ var }}                    variable substitution
  * {% if var %} ... {% endif %} include block if var is truthy

This lets the local test harness render the SAME .j2 files that Ansible
renders in production, so what we validate here is what ships. Real
Ansible runs use full Jinja2; this is only for offline validation.

  usage: render.py <template.j2> KEY=VALUE [KEY=VALUE ...]
"""
import re, sys

def main():
    tmpl_path = sys.argv[1]
    ctx = {}
    for arg in sys.argv[2:]:
        k, _, v = arg.partition("=")
        ctx[k] = v
    with open(tmpl_path) as fh:
        text = fh.read()

    # Handle {% if VAR %}...{% endif %} (non-nested, line-oriented).
    def if_block(m):
        var = m.group(1).strip()
        body = m.group(2)
        return body if ctx.get(var) else ""
    text = re.sub(r"{%\s*if\s+([\w]+)\s*%}(.*?){%\s*endif\s*%}",
                  if_block, text, flags=re.S)

    # Variable substitution.
    def sub(m):
        key = m.group(1).strip()
        if key not in ctx:
            sys.stderr.write(f"render: missing var '{key}'\n")
            sys.exit(3)
        return ctx[key]
    text = re.sub(r"{{\s*([\w]+)\s*}}", sub, text)

    sys.stdout.write(text)

if __name__ == "__main__":
    main()
