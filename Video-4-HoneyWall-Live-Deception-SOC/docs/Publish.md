<!-- filepath: https://github.com/rabakuku/Youtube/blob/main/Video-4-HoneyWall-Live-Deception-SOC/docs/Publish.md -->
# Publishing to GitHub (bdx01 → `rabakuku/Youtube`)

Every build stage ends with one tarball, `Video-4-HoneyWall-Live-Deception-SOC.tar.gz`, containing the **whole** folder so far. You publish it from your git machine (**bdx01**, outside the lab) into the monorepo clone at `~/Youtube`. The lab never pushes to GitHub, and no lab credentials ever touch the git machine.

```text
 claude.ai download ──▶ bdx01:/home/beldex/<folder>.tar.gz ──▶ ~/Youtube/<folder> ──▶ git push (SSH key) ──▶ GitHub
                                                                                                   │
 Alpine setup.sh / Kali campaign ◀── raw.githubusercontent.com ◀──────────────────────────────────┘
```

## One-time prerequisites on bdx01

```bash
ssh -T git@github.com                      # "Hi rabakuku! You've successfully authenticated" (exit code 1 is normal)
git clone git@github.com:rabakuku/Youtube.git ~/Youtube     # if not cloned yet
git -C ~/Youtube config user.name  "<your name>"
git -C ~/Youtube config user.email "<your email>"
```

Get the helper script itself once (after Stage 4 is published, or from the tarball):

```bash
tar -xzOf ~/Video-4-HoneyWall-Live-Deception-SOC.tar.gz \
  Video-4-HoneyWall-Live-Deception-SOC/scripts/publish.sh > ~/publish.sh && chmod +x ~/publish.sh
```

## Each stage

1. Download the tarball and put it in `/home/beldex/`, for example `mv ~/Downloads/Video-4-HoneyWall-Live-Deception-SOC.tar.gz ~/`, or `scp` it from your PC.
2. Preview what will change (touches nothing):

   ```bash
   ~/publish.sh --dry-run
   ```

3. Publish:

   ```bash
   ~/publish.sh --sentinel-file scripts/setup.sh --sentinel-string 'HoneyWall' -m "Video-4: Stage 4 - scripts"
   ```

`publish.sh` stops at the first problem, so a wrong archive never deletes the published folder. It runs these checks in order:

| Check | Why |
|---|---|
| GitHub SSH key works | Fails fast instead of half-way through |
| Repo is on `main` and has no local edits inside the folder | Avoids overwriting work you haven't committed |
| `git pull --ff-only` | Never pushes on top of a stale clone |
| The archive has exactly one top folder, plus the **sentinel** file and text | Proves it's the new archive before anything is deleted |
| Secret scan, and no real `.env` inside | Keeps tokens out of a public repo. Decoy files under `compose/honeyfs/` are fake by design and excluded |
| `diff -rq` against the current folder | Shows what changes |
| `git rm`, extract, `git add`, then confirm every file is tracked | Catches `.gitignore` rules (e.g. `.env*`) that would silently drop `.env.example` |
| Commit and push, then print the GitHub link | Done |

The **sentinel** is a file plus a string that only exists in the new version. Each stage's chat message tells you which to use. If you don't pass one, the default is `docs/Lab-Matrix.md` containing `HoneyWall`.

## The same thing without the helper

This is the one-liner each stage prints:

```bash
cd ~/Youtube && git pull &&
ARCHIVE=/home/beldex/Video-4-HoneyWall-Live-Deception-SOC.tar.gz &&
[ -f "$ARCHIVE" ] && tar -xzOf "$ARCHIVE" Video-4-HoneyWall-Live-Deception-SOC/<sentinel-file> | grep -q '<sentinel-string>' &&
git rm -r -q --ignore-unmatch Video-4-HoneyWall-Live-Deception-SOC && rm -rf Video-4-HoneyWall-Live-Deception-SOC &&
tar -xzf "$ARCHIVE" &&
git add Video-4-HoneyWall-Live-Deception-SOC &&
git commit -m "Video-4-HoneyWall-Live-Deception-SOC: Stage N - <summary>" &&
git push origin main
```

## Retiring the old Video 4 folder

The old `Video-4-Active-Honeypot-Instant-Auto-Quarantine` folder stays online until the new README is live (Stage 7). Then remove it in the same commit as a publish:

```bash
~/publish.sh --retire Video-4-Active-Honeypot-Instant-Auto-Quarantine -m "Video-4: HoneyWall replaces the old honeypot lab"
```

## Undo a bad push

```bash
cd ~/Youtube
git log --oneline -5             # find the bad commit
git revert <commit> && git push  # adds an "undo" commit - safe on a shared main branch
```

## Common problems

| Symptom | Fix |
|---|---|
| `GitHub SSH auth failed` | `ssh-add -l` should list your key; `ssh -T git@github.com`; check the key under GitHub → Settings → SSH keys |
| `git pull failed (diverged?)` | Someone pushed from another machine: `git pull --rebase`, resolve, then rerun |
| `sentinel text not found` | You downloaded an older tarball; download it again |
| `files ignored by a .gitignore rule` | Nothing was committed. Run `git add -f <files>`, commit and push, or fix the rule |
| Alpine still downloads old files | The raw.githubusercontent.com cache takes up to ~5 minutes; wait, then `./setup.sh --update` |
