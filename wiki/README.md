# Backfort GitHub Wiki sources

This directory contains the Markdown pages for the Backfort GitHub Wiki.
GitHub keeps a wiki in a separate repository (`<repository>.wiki.git`), so
publish these files there when the project Wiki is enabled.

```bash
git clone https://github.com/shellharbor/backfort.wiki.git
cp /path/to/backfort/wiki/*.md backfort.wiki/
cd backfort.wiki
git add .
git commit -m "docs: update Backfort wiki"
git push
```

`Home.md` is the landing page and `_Sidebar.md` is GitHub Wiki navigation.
Keep page names stable where possible, because external documentation may link
to them. The repository rule in `AGENTS.md` requires these pages to be kept in
sync with every project change. Maintainers also review the root `SKILL.md` in
the same change so the repository's agent workflow remains aligned with the
public operating contract. GitHub-facing community documents (`CONTRIBUTING.md`,
`SECURITY.md`, `CODE_OF_CONDUCT.md`, and `SUPPORT.md`) are maintained at the
repository root; update their README and Wiki links when that routing changes.
