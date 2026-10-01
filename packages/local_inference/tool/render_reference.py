"""Reference renderings of the core package's chat-template cases, with jinja2 as Hugging Face renders them.

Hugging Face `tokenizer.apply_chat_template` (what fine-tunes are trained with) renders in an
ImmutableSandboxedEnvironment with trim_blocks/lstrip_blocks and loop controls, the `raise_exception` global and a
`tojson` filter that is Python's json.dumps with ensure_ascii=False; tools go to the template only when there are
some, the case's variables (enable_thinking, ...) as keyword arguments. Each case of
test/fixtures/reference/cases.json is rendered with each template it names (test/fixtures/chat_template.jinja, the
Qwen3.5-2B one, and chat_template_4b.jinja, the 4B one) into test/fixtures/reference/<case>.<template>.txt, the tools
taken by name from test/fixtures/toy_tools.json. test/chat_template_test.dart compares JinjaChatTemplate and
ChatModel.render with these files byte for byte.

Usage (from packages/local_inference, in a venv made with python3 -m venv tool/.venv and
tool/.venv/bin/pip install -r tool/requirements.txt):
  tool/.venv/bin/python tool/render_reference.py           # write the files
  tool/.venv/bin/python tool/render_reference.py --check   # compare with the committed files; exit 1 on a difference
"""
from __future__ import annotations

import importlib.metadata
import json
import pathlib
import sys

import jinja2
from jinja2.ext import loopcontrols
from jinja2.sandbox import ImmutableSandboxedEnvironment

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "test" / "fixtures"
REFERENCE = FIXTURES / "reference"
REQUIREMENTS = ROOT / "tool" / "requirements.txt"


def tojson(x, ensure_ascii=False, indent=None, separators=None, sort_keys=False):
    # transformers/utils/chat_template_utils.py: _tojson
    return json.dumps(x, ensure_ascii=ensure_ascii, indent=indent, separators=separators, sort_keys=sort_keys)


def raise_exception(message):
    raise jinja2.exceptions.TemplateError(message)


def pinned_versions_problem() -> str | None:
    """The renderings depend on jinja2: refuse other versions than tool/requirements.txt pins."""
    pins = {}
    for line in REQUIREMENTS.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if "==" in line:
            name, version = line.split("==", 1)
            pins[name.strip().lower()] = version.strip()
    installed = {name: importlib.metadata.version(name) for name in ("jinja2", "markupsafe")}
    wrong = [f"{name} {installed[name]} (pinned {version})" for name, version in pins.items()
             if name in installed and installed[name] != version]
    return ", ".join(wrong) if wrong else None


def render_all() -> dict[str, str]:
    """File name -> rendered prompt, for every case and template."""
    manifest = json.loads((REFERENCE / "cases.json").read_text(encoding="utf-8"))
    declarations = json.loads((FIXTURES / "toy_tools.json").read_text(encoding="utf-8"))
    by_name = {d["function"]["name"]: d for d in declarations}
    env = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True, extensions=[loopcontrols])
    env.filters["tojson"] = tojson
    env.globals["raise_exception"] = raise_exception
    templates = {tag: env.from_string((FIXTURES / file).read_text(encoding="utf-8"))
                 for tag, file in manifest["templates"].items()}
    out = {}
    for case in manifest["cases"]:
        tools = [by_name[name] for name in case["tools"]]
        for tag, template in templates.items():
            kwargs = dict(case["variables"])
            if tools:
                kwargs["tools"] = tools
            prompt = template.render(messages=case["messages"],
                                     add_generation_prompt=case["add_generation_prompt"], **kwargs)
            out[f"{case['name']}.{tag}.txt"] = prompt
    return out


def main(argv: list[str]) -> int:
    check = argv == ["--check"]
    if argv and not check:
        print(__doc__, file=sys.stderr)
        return 2
    problem = pinned_versions_problem()
    if problem:
        print(f"render_reference: wrong versions: {problem}; use tool/.venv (installed from tool/requirements.txt)",
              file=sys.stderr)
        return 2
    rendered = render_all()
    committed = {path.name for path in REFERENCE.glob("*.txt")}
    if check:
        failures = []
        for name, prompt in rendered.items():
            path = REFERENCE / name
            if not path.exists():
                failures.append(f"{name}: missing")
            elif path.read_bytes() != prompt.encode("utf-8"):
                failures.append(f"{name}: differs from its rendering")
        failures += [f"{name}: no case renders it" for name in sorted(committed - rendered.keys())]
        for failure in failures:
            print(f"render_reference: {failure}", file=sys.stderr)
        if failures:
            return 1
        print(f"render_reference: {len(rendered)} renderings equal the committed files")
        return 0
    for name in sorted(committed - rendered.keys()):
        (REFERENCE / name).unlink()
    for name, prompt in rendered.items():
        (REFERENCE / name).write_bytes(prompt.encode("utf-8"))
        print(f"{name}  {len(prompt)} chars")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
