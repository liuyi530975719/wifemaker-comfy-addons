# Push this folder to GitHub

```powershell
# 1) Set username (replace liuyi530975719 first in README.md + install.sh)
cd C:\Users\besty\Desktop\wifemaker-comfy-addons
# Use VS Code's find-and-replace or:
(Get-Content README.md)  -replace 'liuyi530975719','YourGitHubUsername' | Set-Content README.md
(Get-Content install.sh) -replace 'liuyi530975719','YourGitHubUsername' | Set-Content install.sh

# 2) Init git + first commit
git init
git add .
git commit -m "Initial commit â€?wifemaker custom nodes v1"
git branch -M main

# 3) Create the repo on github.com (web UI or gh cli)
gh repo create wifemaker-comfy-addons --public --source=. --remote=origin --push
# Or manually:
# git remote add origin git@github.com:<USER>/wifemaker-comfy-addons.git
# git push -u origin main

# 4) Test the one-liner from a fresh shell (vast.ai or any Linux box):
curl -fsSL https://raw.githubusercontent.com/<USER>/wifemaker-comfy-addons/main/install.sh | bash
```

## If you want it private

Make the repo private on GitHub, then add a Personal Access Token to the curl:

```bash
# Generate PAT at: github.com/settings/tokens (classic, scope: repo)
export GH=ghp_xxxxxxxxxxxxxxxxxxxx

curl -fsSL -H "Authorization: token $GH" \
  https://raw.githubusercontent.com/<USER>/wifemaker-comfy-addons/main/install.sh | \
  GITHUB_TOKEN=$GH bash
```

Then edit `install.sh`'s `git clone` line to:
```bash
git clone --depth 1 -c "http.extraHeader=Authorization: token $GITHUB_TOKEN" \
  "$REPO_URL" "$SRC_DIR"
```
