#!/usr/bin/env python3
"""Dependency-free repository check. Requires Ruby + minitest and Node.js for tests."""
from pathlib import Path
from urllib.parse import unquote
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(command: list[str]) -> None:
    print('\n$ ' + ' '.join(command), flush=True)
    subprocess.run(command, cwd=ROOT, check=True)


def main() -> int:
    required = ['SKILL.md', 'README.md', 'agents/openai.yaml',
                'references/generation-animation.md', 'scripts/sketchup_studio.rb',
                'examples/animated_pavilion.rb', 'examples/task_template.rb']
    for name in required:
        if not (ROOT / name).is_file():
            raise ValueError('Missing required file: ' + name)
    skill = (ROOT / 'SKILL.md').read_text(encoding='utf-8')
    if not skill.startswith('---\n') or 'name: sketchup-design-studio' not in skill:
        raise ValueError('Skill frontmatter invalid')
    if 'version: "1.2.1"' not in skill:
        raise ValueError('Skill version mismatch')
    broken = []
    for md in ROOT.rglob('*.md'):
        for target in re.findall(r'(?<!!)\[[^\]]*\]\(([^)]+)\)', md.read_text(encoding='utf-8')):
            if '://' in target or target.startswith(('#', 'mailto:')):
                continue
            relative = unquote(target.split('#')[0])
            if relative and not (md.parent / relative).exists():
                broken.append(f'{md.relative_to(ROOT)} -> {target}')
    if broken:
        raise ValueError('Broken local Markdown references:\n' + '\n'.join(broken))
    for name in ('ruby', 'node'):
        if not shutil.which(name):
            raise RuntimeError(f'{name} is required for development checks, not for SketchUp runtime use.')
    print('Structure, Skill frontmatter, version and local Markdown links: PASS', flush=True)
    run(['ruby', '-v'])
    run(['node', '-v'])
    for rb in sorted(ROOT.rglob('*.rb')):
        if '.git' not in rb.parts:
            run(['ruby', '-c', str(rb.relative_to(ROOT))])
    for js in sorted(ROOT.rglob('*.js')):
        if '.git' not in js.parts:
            run(['node', '--check', str(js.relative_to(ROOT))])
    run(['ruby', '-Itests', '-e', 'Dir["tests/*_test.rb"].sort.each { |f| require_relative f }'])
    run(['node', '--test'] + [str(p.relative_to(ROOT)) for p in sorted((ROOT / 'tests').glob('*_test.js'))])
    print('\nPASS — These are mock/static tests, NOT native SketchUp validation.', flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f'FAILED: {exc}', file=sys.stderr)
        sys.exit(1)
