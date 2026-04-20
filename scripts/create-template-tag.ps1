Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Show-Usage {
    @"
Usage: ./scripts/create-template-tag.ps1 --tag vX.Y.Z

Required:
  --tag <value>     Tag to create (example: v2.1.6)

Optional:
  -h, --help        Show this help text

Behavior:
  1) Updates .wombat-cc-version
  2) Commits .wombat-cc-version if it changed
  3) Creates an annotated git tag
"@ | Write-Host
}

$tag = ""

for ($i = 0; $i -lt $args.Count; $i++) {
    $arg = [string]$args[$i]

    if ($arg -eq "--tag") {
        if ($i + 1 -ge $args.Count) {
            throw "Error: --tag requires a value"
        }
        $tag = [string]$args[$i + 1]
        $i++
        continue
    }

    if ($arg.StartsWith("--tag=")) {
        $tag = $arg.Substring(6)
        continue
    }

    if ($arg -eq "-h" -or $arg -eq "--help") {
        Show-Usage
        exit 0
    }

    throw "Error: unknown argument '$arg'"
}

if ([string]::IsNullOrWhiteSpace($tag)) {
    Show-Usage
    throw "Error: --tag is required"
}

if ($tag -notmatch '^v\d+\.\d+\.\d+$') {
    throw "Error: tag must match vX.Y.Z (example: v2.1.6)"
}

git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Error: run this command inside a git repository"
}

git rev-parse -q --verify "refs/tags/$tag" *> $null
if ($LASTEXITCODE -eq 0) {
    throw "Error: tag '$tag' already exists"
}

git remote get-url origin *> $null
if ($LASTEXITCODE -eq 0) {
    git ls-remote --exit-code --tags origin "refs/tags/$tag" "refs/tags/$tag^{}" *> $null
    if ($LASTEXITCODE -eq 0) {
        throw "Error: tag '$tag' already exists on remote 'origin'"
    }
    if ($LASTEXITCODE -ne 2) {
        throw "Error: failed to verify whether tag '$tag' exists on remote 'origin'"
    }
}
else {
    Write-Warning "No 'origin' remote found; remote tag existence check was skipped."
}

Set-Content -Path ".wombat-cc-version" -Value $tag
git add .wombat-cc-version

git diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
    git commit -m "chore: bump .wombat-cc-version to $tag"
}
else {
    Write-Host ".wombat-cc-version already set to $tag; skipping commit"
}

git tag -a $tag -m "Release $tag"
Write-Host "Created tag '$tag'"
Write-Host "Next: git push origin main $tag"
