# Intellite sync for Windows (Windows PowerShell 5.1 or later).
#   intellite-sync hook claude|codex     SessionStart hook: sync the Stack into the skills folder, print the hook output
#                                        (instructions: given in full; hook input on stdin, cwd)
#   intellite-sync connect               OAuth 2.0 authorization code, PKCE, loopback redirect; scope methods.stack.read
#   intellite-sync status
#   intellite-sync disconnect <id>       revoke the connection, remove its skills
#   intellite-sync assign <id> <folder>  give an organization's instructions in <folder> (two organizations or more)
#   intellite-sync unassign <id> <folder>
# Refresh tokens: DPAPI (CurrentUser); never printed, logged or passed on a command line.
# ASCII only: Windows PowerShell 5.1 reads a script without a byte order mark in the ANSI code page.
param([Parameter(Position = 0)][string]$Command = "status", [Parameter(Position = 1)][string]$Argument = "", [Parameter(Position = 2)][string]$Folder = "", [switch]$NoBrowser)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Security

$ClientId = "intellite-methods-plugin"
$Scope = "methods.stack.read"
$Utf8 = New-Object System.Text.UTF8Encoding $false
$Started = [DateTime]::UtcNow
# A session waits for its start hooks: past this, the session starts with the skills as they are.
$BudgetSeconds = 10
# The characters of the instructions given at the start of a session: Claude Code takes up to 10,000 from a hook, and
# what changed and the notes need room too.
$InstructionBudget = 8000

function Get-Issuer {
  $value = $env:INTELLITE_SYNC_ISSUER
  if (-not $value) { return "https://intellite.app" }
  $value = $value.TrimEnd("/")
  # Intellite, or one on this computer: never another server, which could hand out its own skills.
  if ($value -eq "https://intellite.app") { return $value }
  if ($value -match '^http://(127\.0\.0\.1|localhost):[0-9]{2,5}$') { return $value }
  throw "INTELLITE_SYNC_ISSUER must be https://intellite.app or http://127.0.0.1:<port>."
}
# A start hook never fails a session, not even for a misnamed Intellite: it starts with the skills as they are.
try { $Issuer = Get-Issuer } catch { if ($Command -eq "hook") { exit 0 }; throw }
$Resource = "$Issuer/apps/intellite-methods"
$Home_ = [Environment]::GetFolderPath("UserProfile")
$Place = ($Issuer -replace '^https?://', '') -replace '[^A-Za-z0-9.-]', '-'
$Root = Join-Path $Home_ ".intellite\sync\$Place"
# INTELLITE_SYNC_STATE, INTELLITE_SYNC_CLAUDE_SKILLS and INTELLITE_SYNC_CODEX_SKILLS override the paths.
if ($env:INTELLITE_SYNC_STATE) { $Root = $env:INTELLITE_SYNC_STATE }

function Get-SkillsFolder([string]$Tool) {
  if ($Tool -eq "claude" -and $env:INTELLITE_SYNC_CLAUDE_SKILLS) { return $env:INTELLITE_SYNC_CLAUDE_SKILLS }
  if ($Tool -eq "codex" -and $env:INTELLITE_SYNC_CODEX_SKILLS) { return $env:INTELLITE_SYNC_CODEX_SKILLS }
  if ($Tool -eq "claude") {
    if ($env:CLAUDE_CONFIG_DIR) { return Join-Path $env:CLAUDE_CONFIG_DIR "skills" }
    return Join-Path $Home_ ".claude\skills"
  }
  if ($Tool -eq "codex") { return Join-Path $Home_ ".agents\skills" }
  throw "The AI tool is claude or codex."
}

# --- small helpers -----------------------------------------------------------------------------------------------------

function Get-Hex([byte[]]$Bytes) { return (($Bytes | ForEach-Object { $_.ToString("x2") }) -join "") }
function Get-Sha256([byte[]]$Bytes) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return Get-Hex $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
}
function Get-RandomBytes([int]$Count) {
  $bytes = New-Object byte[] $Count
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  return ,$bytes
}
function ConvertTo-Base64Url([byte[]]$Bytes) { return [Convert]::ToBase64String($Bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_") }
function Get-Field($Object, [string]$Name) {
  if ($null -eq $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($property) { return $property.Value }
  return $null
}
# JSON for an AI tool to read: every character beyond ASCII written as \uXXXX, so that no console code page changes it.
function ConvertTo-AsciiJson($Value) {
  $json = ConvertTo-Json -InputObject $Value -Depth 8 -Compress
  $builder = New-Object System.Text.StringBuilder
  foreach ($char in $json.ToCharArray()) {
    if ([int]$char -gt 126) { [void]$builder.AppendFormat("\u{0:x4}", [int]$char) } else { [void]$builder.Append($char) }
  }
  return $builder.ToString()
}
function Read-Json([string]$Path, $Default) {
  if (-not (Test-Path -LiteralPath $Path)) { return $Default }
  try { return [System.IO.File]::ReadAllText($Path, $Utf8) | ConvertFrom-Json } catch { return $Default }
}
function Write-Json([string]$Path, $Value) {
  $temp = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
  # -InputObject: an array of one item stays an array.
  [System.IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 8), $Utf8)
  Move-Item -LiteralPath $temp -Destination $Path -Force
}
function Get-Message([string]$Body) {
  try { return [string](Get-Field ($Body | ConvertFrom-Json) "message") } catch { return "" }
}
function Write-Log([string]$Text) {
  try {
    $path = Join-Path $Root "sync.log"
    $lines = @()
    if (Test-Path -LiteralPath $path) { $lines = @([System.IO.File]::ReadAllLines($path, $Utf8) | Select-Object -Last 199) }
    [System.IO.File]::WriteAllLines($path, [string[]]($lines + ([DateTime]::UtcNow.ToString("o") + " " + $Text)), $Utf8)
  } catch { }
}
function Test-Link([string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  return ($null -ne $item) -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}
function Get-SecondsLeft { return $BudgetSeconds - ([DateTime]::UtcNow - $Started).TotalSeconds }

# --- HTTP --------------------------------------------------------------------------------------------------------------

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$Http = New-Object System.Net.Http.HttpClient
$Http.Timeout = [TimeSpan]::FromSeconds(5)
$Http.DefaultRequestHeaders.UserAgent.ParseAdd("intellite-sync/1 (Windows PowerShell)")

# One request: { Status, Body (text), ETag }. Status 0 when the network failed or the time ran out.
function Invoke-Http([string]$Method, [string]$Url, [string]$Token = "", [hashtable]$Form = $null, [string]$ETag = "") {
  # After one request that reached nothing, the rest of this run does not wait again: the session starts as it is.
  if ($script:Offline -or (Get-SecondsLeft) -le 0) { return @{ Status = 0; Body = ""; ETag = "" } }
  $request = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::new($Method)), $Url
  if ($Token) { $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue "Bearer", $Token }
  if ($ETag) { [void]$request.Headers.TryAddWithoutValidation("If-None-Match", $ETag) }
  [void]$request.Headers.TryAddWithoutValidation("Accept", "application/json")
  if ($Form) {
    $pairs = New-Object 'System.Collections.Generic.List[System.Collections.Generic.KeyValuePair[string,string]]'
    foreach ($key in $Form.Keys) { $pairs.Add((New-Object 'System.Collections.Generic.KeyValuePair[string,string]' -ArgumentList ([string]$key), ([string]$Form[$key]))) }
    $request.Content = New-Object System.Net.Http.FormUrlEncodedContent (,$pairs)
  }
  try {
    $response = $Http.SendAsync($request).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $tag = ""
    if ($response.Headers.ETag) { $tag = $response.Headers.ETag.ToString() }
    return @{ Status = [int]$response.StatusCode; Body = $Utf8.GetString($body); ETag = $tag }
  } catch {
    $script:Offline = $true
    return @{ Status = 0; Body = ""; ETag = "" }
  } finally { $request.Dispose() }
}

# --- connections and their refresh tokens --------------------------------------------------------------------------------

function Get-Connections { $value = Read-Json (Join-Path $Root "connections.json") $null; if ($null -eq $value) { return @() }; return @($value) }
function Save-Connections($List) { Write-Json (Join-Path $Root "connections.json") @($List) }
function Get-SecretPath([string]$Id) { return Join-Path $Root "$Id.dpapi" }
function Save-RefreshToken([string]$Id, [string]$Token) {
  $protected = [System.Security.Cryptography.ProtectedData]::Protect($Utf8.GetBytes($Token), $Utf8.GetBytes("intellite-sync"), [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
  $path = Get-SecretPath $Id
  $temp = "$path.tmp"
  [System.IO.File]::WriteAllBytes($temp, $protected)
  Move-Item -LiteralPath $temp -Destination $path -Force
}
function Get-RefreshToken([string]$Id) {
  $path = Get-SecretPath $Id
  if (-not (Test-Path -LiteralPath $path)) { return "" }
  try {
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([System.IO.File]::ReadAllBytes($path), $Utf8.GetBytes("intellite-sync"), [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return $Utf8.GetString($bytes)
  } catch { return "" }
}
function Remove-RefreshToken([string]$Id) { Remove-Item -LiteralPath (Get-SecretPath $Id) -Force -ErrorAction SilentlyContinue }

# An access token for a connection, from its refresh token, which is replaced at once by the new one (each is used once).
# Returns "" with $script:Ended set when Intellite says the connection is over, and "" alone when it could not be reached.
function Get-AccessToken($Connection) {
  $script:Ended = $false
  $refresh = Get-RefreshToken $Connection.id
  if (-not $refresh) { $script:Ended = $true; return "" }
  $answer = Invoke-Http "POST" "$Issuer/oauth/token" "" @{ grant_type = "refresh_token"; refresh_token = $refresh; client_id = $ClientId; resource = $Resource }
  if ($answer.Status -eq 200) {
    $token = $answer.Body | ConvertFrom-Json
    if ($token.refresh_token) { Save-RefreshToken $Connection.id $token.refresh_token }
    return [string]$token.access_token
  }
  if ($answer.Status -eq 400 -or $answer.Status -eq 401) { $script:Ended = $true }
  return ""
}

# --- the instructions each connection gave ------------------------------------------------------------------------------

function Get-InstructionsPath([string]$Id) { return Join-Path $Root "instructions-$Id.json" }
function Get-Instructions([string]$Id) { $value = Read-Json (Get-InstructionsPath $Id) $null; if ($null -eq $value) { return @() }; return @($value) }
# Keeps what the list gave, each checked against its SHA-256: a text that does not match is not kept.
function Save-Instructions([string]$Id, $List) {
  $kept = New-Object System.Collections.ArrayList
  foreach ($item in @($List)) {
    if (-not $item) { continue }
    if ((Get-Sha256 $Utf8.GetBytes([string]$item.text)) -ne [string]$item.sha256) { Write-Log "instruction $($item.name) $($item.version): the text does not match its SHA-256"; continue }
    [void]$kept.Add([pscustomobject]@{ name = [string]$item.name; methodId = [string]$item.methodId; version = [int]$item.version; title = [string]$item.title;
      organization = [bool]$item.organization; digest = [string]$item.digest; text = [string]$item.text })
  }
  Write-Json (Get-InstructionsPath $Id) @($kept)
}

# The folder the session works in, from the hook's input on stdin (Claude Code and Codex send its cwd). Read for at most
# a second and a half, so that a hook started without input does not wait.
function Get-SessionFolder {
  try {
    if (-not [Console]::IsInputRedirected) { return "" }
    $reading = [Console]::In.ReadToEndAsync()
    if (-not $reading.Wait(1500)) { return "" }
    return [string](Get-Field ($reading.Result | ConvertFrom-Json) "cwd")
  } catch { return "" }
}
function Test-Within([string]$Place, [string]$Parent) {
  if (-not $Place -or -not $Parent) { return $false }
  $placePath = [System.IO.Path]::GetFullPath($Place).TrimEnd("\") + "\"
  $parentPath = [System.IO.Path]::GetFullPath($Parent).TrimEnd("\") + "\"
  return $placePath.StartsWith($parentPath, [StringComparison]::OrdinalIgnoreCase)
}

# The instructions for a session in that folder: an organization's first, then the user's own. An organization's are
# given everywhere while it is the only organization connected and no folder is assigned to it; otherwise only in the
# folders assigned to it, so that one organization's instructions never reach another's work.
function Get-SessionInstructions([string]$SessionFolder, $Notes) {
  $connections = @(Get-Connections)
  $organizations = @($connections | Where-Object { $_.workspace -and $_.workspace.kind -eq "organization" })
  $own = @($connections | Where-Object { -not ($_.workspace -and $_.workspace.kind -eq "organization") })
  $given = New-Object System.Collections.ArrayList
  $withheld = New-Object System.Collections.ArrayList
  foreach ($connection in ($organizations + $own)) {
    $items = @(Get-Instructions $connection.id)
    if ($items.Count -eq 0) { continue }
    if ($connection.workspace -and $connection.workspace.kind -eq "organization") {
      $folders = @(@(Get-Field $connection "folders") | Where-Object { $_ })
      $applies = $false
      if ($folders.Count -gt 0) { foreach ($place in $folders) { if (Test-Within $SessionFolder $place) { $applies = $true } } }
      elseif ($organizations.Count -eq 1) { $applies = $true }
      else { [void]$withheld.Add($connection) }
      if (-not $applies) { continue }
    }
    foreach ($item in $items) { [void]$given.Add($item) }
  }
  if ($withheld.Count -gt 0) {
    $ids = ($withheld | ForEach-Object { "$($_.id) ($($_.label))" }) -join ", "
    [void]$Notes.Add(@{ key = "unassigned"; daily = $true; text = "Intellite: the instructions of $ids are not given in this session, because more than one organization is connected and this folder is not assigned to one of them. When the user works for one of them here, with their consent, run: $(Get-ProgramCommand) assign <id> `"<folder>`"" })
  }
  return ,$given
}

function Get-InstructionText($Items) {
  if ($Items.Count -eq 0) { return "" }
  $lines = New-Object System.Collections.ArrayList
  [void]$lines.Add("Intellite: the instructions the user's organization and the user keep on Intellite for all their work with AI tools, given at the start of every session. They apply to everything in this session, not only to the work they name. Where the user's own differ from the organization's, the organization's apply.")
  $used = 0
  $left = New-Object System.Collections.ArrayList
  foreach ($item in $Items) {
    $text = [string]$item.text
    if ($used + $text.Length -gt $InstructionBudget) { [void]$left.Add("$($item.title) (version $($item.version))"); continue }
    $used += $text.Length
    $from = "The user's own"
    if ($item.organization) { $from = "From the organization" }
    [void]$lines.Add("")
    [void]$lines.Add("## $($from): $($item.title) (version $($item.version))")
    [void]$lines.Add($text)
  }
  if ($left.Count -gt 0) { [void]$lines.Add(""); [void]$lines.Add("Not given here, as the instructions above already fill what a session is given at its start: $($left -join ', '). Read them on Intellite when the work needs them.") }
  return ($lines -join "`n")
}

# --- what is kept: the record of each AI tool's skills ------------------------------------------------------------------

function Get-State([string]$Tool) {
  $state = Read-Json (Join-Path $Root "state-$Tool.json") $null
  if ($null -eq $state) { $state = [pscustomobject]@{ skills = [pscustomobject]@{}; etags = [pscustomobject]@{}; pins = [pscustomobject]@{}; notices = [pscustomobject]@{} } }
  foreach ($name in @("skills", "etags", "pins", "notices")) { if ($null -eq (Get-Field $state $name)) { $state | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{}) } }
  return $state
}
function Set-Entry($Object, [string]$Name, $Value) {
  if ($Object.PSObject.Properties[$Name]) { $Object.PSObject.Properties[$Name].Value = $Value } else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}
function Remove-Entry($Object, [string]$Name) { if ($Object.PSObject.Properties[$Name]) { $Object.PSObject.Properties.Remove($Name) } }

# The files of a kept skill as they are now, compared with what was written: true when every one is unchanged.
function Test-Unchanged([string]$Folder, $Files) {
  if (-not (Test-Path -LiteralPath $Folder -PathType Container) -or (Test-Link $Folder)) { return $false }
  foreach ($property in $Files.PSObject.Properties) {
    $path = Join-Path $Folder $property.Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Test-Link $path)) { return $false }
    if ((Get-Sha256 ([System.IO.File]::ReadAllBytes($path))) -ne $property.Value) { return $false }
  }
  return $true
}

# Takes a kept skill's folder out: into the record's folder of removed skills when it was stopped as harmful (so nothing
# is lost), deleted otherwise. Only a real folder, never a link.
function Remove-SkillFolder([string]$Folder, [bool]$Keep) {
  if (-not (Test-Path -LiteralPath $Folder)) { return }
  if (Test-Link $Folder) { return }
  if ($Keep) {
    $place = Join-Path $Root ("removed\" + [DateTime]::UtcNow.ToString("yyyyMMddHHmmss") + "-" + (Split-Path $Folder -Leaf))
    New-Item -ItemType Directory -Force (Split-Path $place -Parent) | Out-Null
    Move-Item -LiteralPath $Folder -Destination $place -Force
  } else { Remove-Item -LiteralPath $Folder -Recurse -Force }
}

# Writes the files of one version into a new folder beside the skills, checks each against its SHA-256 and the version's
# pin, and then puts the folder in place of the skill's. Returns "" when done, or why it was not.
function Install-Skill([string]$SkillsFolder, $Skill, $Bundle, $State) {
  $name = [string]$Skill.name
  if ($name -notmatch '^intellite-[a-z0-9]+(-[a-z0-9]+)*$') { return "its name is not an Intellite skill name" }
  $pinKey = "$($Skill.methodId)@$($Skill.version)"
  $pin = Get-Field $State.pins $pinKey
  $files = [pscustomobject]@{}
  $temp = Join-Path $SkillsFolder (".intellite-new-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force $temp | Out-Null
  try {
    foreach ($file in @($Bundle.files)) {
      $path = [string]$file.path
      if ($path -ne "SKILL.md" -and $path -ne "intellite-method.json") { return "it carries a file other than SKILL.md and intellite-method.json" }
      $bytes = $Utf8.GetBytes([string]$file.text)
      $sha = Get-Sha256 $bytes
      if ($sha -ne [string]$file.sha256) { return "$path does not match its SHA-256" }
      if ($pin -and (Get-Field $pin $path) -and (Get-Field $pin $path) -ne $sha) { return "version $($Skill.version) came with other content than before (a published version never changes)" }
      [System.IO.File]::WriteAllBytes((Join-Path $temp $path), $bytes)
      Set-Entry $files $path $sha
    }
    if (-not (Get-Field $files "SKILL.md")) { return "it has no SKILL.md" }
    $target = Join-Path $SkillsFolder $name
    if (Test-Path -LiteralPath $target) {
      if (Test-Link $target) { return "$target is a link" }
      $kept = Get-Field $State.skills $name
      if (-not $kept) {
        # A folder this program did not write: replaced only when its SKILL.md names the same post.
        $skillFile = Join-Path $target "SKILL.md"
        $same = (Test-Path -LiteralPath $skillFile -PathType Leaf) -and -not (Test-Link $skillFile) -and
          ([System.IO.File]::ReadAllText($skillFile, $Utf8) -match ("(?m)^\s*intellite-method-id:\s*""" + [regex]::Escape([string]$Skill.methodId) + """\s*$"))
        if (-not $same) { return "a folder of that name is already there and is not this post's" }
      } elseif (-not (Test-Unchanged $target $kept.files)) { return "it was changed on this computer, so it was left as it is" }
      $old = Join-Path $SkillsFolder (".intellite-old-" + [Guid]::NewGuid().ToString("N"))
      [System.IO.Directory]::Move($target, $old)
      [System.IO.Directory]::Move($temp, $target)
      Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
    } else {
      [System.IO.Directory]::Move($temp, $target)
    }
    Set-Entry $State.pins $pinKey $files
    Set-Entry $State.skills $name ([pscustomobject]@{ connection = $Skill.connection; methodId = $Skill.methodId; version = $Skill.version; title = $Skill.title;
      organization = [bool]$Skill.organization; digest = [string](Get-Field $Bundle.method "digest"); files = $files })
    return ""
  } finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

function Get-Description([string]$SkillFolder) {
  $path = Join-Path $SkillFolder "SKILL.md"
  if (-not (Test-Path -LiteralPath $path)) { return "" }
  $match = [regex]::Match([System.IO.File]::ReadAllText($path, $Utf8), '(?m)^description:\s*(".*")\s*$')
  if (-not $match.Success) { return "" }
  try { return [string]($match.Groups[1].Value | ConvertFrom-Json) } catch { return "" }
}

# --- one sync of one AI tool's skills -------------------------------------------------------------------------------------

function Sync-Tool([string]$Tool, [string]$SessionFolder) {
  $skillsFolder = Get-SkillsFolder $Tool
  New-Item -ItemType Directory -Force $skillsFolder | Out-Null
  $state = Get-State $Tool
  $connections = @(Get-Connections)
  $changes = New-Object System.Collections.ArrayList
  $notes = New-Object System.Collections.ArrayList
  $now = [DateTime]::UtcNow

  foreach ($connection in $connections) {
    if ($connection.ended) { continue }
    $access = Get-AccessToken $connection
    if (-not $access) {
      if ($script:Ended) { $connection | Add-Member -NotePropertyName ended -NotePropertyValue $now.ToString("o") -Force }
      continue
    }
    $etag = [string](Get-Field $state.etags $connection.id)
    # Kept unchanged when a version could not be put in place, so that the next session tries again.
    $complete = $true
    $answer = Invoke-Http "GET" "$Resource/skills" $access $null $etag
    if ($answer.Status -eq 304) { continue }
    if ($answer.Status -ne 200) {
      # Refused by the organization's rules (a network or sign-in rule): nothing is taken out, the AI is told once a day.
      if ($answer.Status -eq 401 -or $answer.Status -eq 403) { [void]$notes.Add(@{ key = "refused-$($connection.id)"; daily = $true; text = "Intellite refused the update of the skills from $($connection.label) (HTTP $($answer.Status)): $(Get-Message $answer.Body) The skills already here stay as they are." }) }
      Write-Log "list of $($connection.id): HTTP $($answer.Status)"
      continue
    }
    $list = $answer.Body | ConvertFrom-Json
    Save-Instructions $connection.id (Get-Field $list "instructions")
    $wanted = @{}
    foreach ($skill in @($list.skills)) {
      if (-not $skill) { continue }
      $skill | Add-Member -NotePropertyName connection -NotePropertyValue $connection.id -Force
      $wanted[[string]$skill.name] = $skill
      $kept = Get-Field $state.skills ([string]$skill.name)
      if ($kept -and $kept.connection -ne $connection.id) { continue }
      $folder = Join-Path $skillsFolder ([string]$skill.name)
      if ($kept -and [int]$kept.version -eq [int]$skill.version -and (Test-Unchanged $folder $kept.files)) { continue }
      $bundleAnswer = Invoke-Http "GET" "$Resource/skills/$($skill.methodId)/$($skill.version)" $access
      if ($bundleAnswer.Status -ne 200) { $complete = $false; Write-Log "files of $($skill.name) $($skill.version): HTTP $($bundleAnswer.Status)"; continue }
      $why = Install-Skill $skillsFolder $skill ($bundleAnswer.Body | ConvertFrom-Json) $state
      if ($why) { [void]$notes.Add(@{ key = "skip-$($skill.name)-$($skill.version)"; text = "Intellite did not put $($skill.name) version $($skill.version) in place: $why." }); $complete = $false; Write-Log "$($skill.name) $($skill.version) not put in place: $why"; continue }
      $kind = "added"
      if ($kept) { $kind = "updated" }
      [void]$changes.Add(@{ kind = $kind; name = [string]$skill.name; version = [int]$skill.version; title = [string]$skill.title; organization = [bool]$skill.organization; folder = $folder })
    }
    # Taken out: what the list says to take out, and what this connection brought that the list no longer gives.
    $reasons = @{}
    foreach ($removal in @($list.remove)) { if ($removal) { $reasons[[string]$removal.name] = [string]$removal.reason } }
    # A post whose version chosen is an instruction now leaves the skills: it is given at the start of each session.
    foreach ($item in @(Get-Field $list "instructions")) { if ($item) { $reasons[[string]$item.name] = "instruction" } }
    foreach ($property in @($state.skills.PSObject.Properties)) {
      $kept = $property.Value
      if ($kept.connection -ne $connection.id -or $wanted.ContainsKey($property.Name)) { continue }
      $reason = "removed"
      if ($reasons.ContainsKey($property.Name)) { $reason = $reasons[$property.Name] }
      $folder = Join-Path $skillsFolder $property.Name
      if ($reason -ne "harmful" -and (Test-Path -LiteralPath $folder) -and -not (Test-Unchanged $folder $kept.files)) {
        [void]$notes.Add(@{ key = "left-$($property.Name)"; text = "Intellite no longer gives $($property.Name), but it was changed on this computer, so it was left in place." })
        Remove-Entry $state.skills $property.Name
        continue
      }
      Remove-SkillFolder $folder ($reason -eq "harmful")
      Remove-Entry $state.skills $property.Name
      [void]$changes.Add(@{ kind = "removed"; name = $property.Name; reason = $reason; title = [string]$kept.title })
    }
    if ($complete) { Set-Entry $state.etags $connection.id $answer.ETag } else { Set-Entry $state.etags $connection.id "" }
    $connection | Add-Member -NotePropertyName syncedAt -NotePropertyValue $now.ToString("o") -Force
    $connection | Add-Member -NotePropertyName workspace -NotePropertyValue $list.workspace -Force
  }

  # Versions stopped as harmful are taken out even without a connection: the list is public and names digests only.
  $instructionsKept = @($connections | Where-Object { @(Get-Instructions $_.id).Count -gt 0 }).Count -gt 0
  if (@($state.skills.PSObject.Properties).Count -gt 0 -or $instructionsKept) {
    $stopped = Invoke-Http "GET" "$Resource/skills/stopped" "" $null ([string](Get-Field $state.notices "stoppedETag"))
    if ($stopped.Status -eq 200) {
      $digests = @(($stopped.Body | ConvertFrom-Json).harmful)
      foreach ($connection in $connections) {
        $items = @(Get-Instructions $connection.id)
        $keep = @($items | Where-Object { -not ($_.digest -and $digests -contains [string]$_.digest) })
        if ($keep.Count -eq $items.Count) { continue }
        foreach ($item in $items) {
          if ($item.digest -and $digests -contains [string]$item.digest) { [void]$changes.Add(@{ kind = "removed"; name = [string]$item.name; reason = "harmful"; title = [string]$item.title; instruction = $true }) }
        }
        Write-Json (Get-InstructionsPath $connection.id) @($keep)
      }
      foreach ($property in @($state.skills.PSObject.Properties)) {
        if ($property.Value.digest -and $digests -contains [string]$property.Value.digest) {
          Remove-SkillFolder (Join-Path $skillsFolder $property.Name) $true
          Remove-Entry $state.skills $property.Name
          [void]$changes.Add(@{ kind = "removed"; name = $property.Name; reason = "harmful"; title = [string]$property.Value.title })
        }
      }
      Set-Entry $state.notices "stoppedETag" $stopped.ETag
    }
  }

  # Ended connections: the AI is told once a day, with what to run to connect again.
  foreach ($connection in $connections) {
    if ($connection.ended) { [void]$notes.Add(@{ key = "ended-$($connection.id)"; daily = $true; text = "Intellite: updates of the skills from $($connection.label) stopped on this computer, because the connection ended (it ends after a time without use, or when it is stopped on Intellite). The skills already here stay and work at their versions. To resume, with the user's consent, run: $(Get-ConnectCommand)" }) }
  }
  if ($connections.Count -eq 0 -and -not (Get-Field $state.notices "offered")) {
    [void]$notes.Add(@{ key = "offered"; text = "Intellite can keep the user's Stack (the methods the user and their organization chose on Intellite) among this computer's skills, so that you use them without the user naming Intellite. It is not connected on this computer. When the user works with Intellite, offer it once; with their consent, run: $(Get-ConnectCommand) (it opens Intellite's consent page in the browser, where the user chooses their own workspace or an organization, and waits up to 5 minutes)." })
  }

  Save-Connections $connections
  $instructions = Get-InstructionText (Get-SessionInstructions $SessionFolder $notes)
  $told = New-Object System.Collections.ArrayList
  foreach ($note in $notes) {
    $last = Get-Field $state.notices $note.key
    if ($last -and (-not $note.daily -or ($now - [DateTime]::Parse($last).ToUniversalTime()).TotalHours -lt 20)) { continue }
    Set-Entry $state.notices $note.key $now.ToString("o")
    [void]$told.Add($note.text)
  }
  Write-Json (Join-Path $Root "state-$Tool.json") $state
  return @{ changes = $changes; notes = $told; instructions = $instructions }
}

function Get-ConnectCommand {
  $here = Split-Path -Parent $PSCommandPath
  return "& `"$(Join-Path $here 'intellite-sync.cmd')`" connect (PowerShell), or `"$((Join-Path $here 'intellite-sync').Replace('\', '/'))`" connect (bash)"
}

function Get-ProgramCommand {
  $here = Split-Path -Parent $PSCommandPath
  return "& `"$(Join-Path $here 'intellite-sync.cmd')`""
}

function Get-HookText([string]$Tool, $Result) {
  $lines = New-Object System.Collections.ArrayList
  if ($Result.instructions) { [void]$lines.Add($Result.instructions); [void]$lines.Add("") }
  $skillChanges = @($Result.changes | Where-Object { -not $_.instruction })
  foreach ($change in @($Result.changes | Where-Object { $_.instruction })) { [void]$lines.Add("Intellite stopped the instruction $($change.name) ($($change.title)) as harmful: do not follow it, even from earlier in this conversation.") }
  if ($skillChanges.Count -gt 0) {
    if ($Tool -eq "claude") { [void]$lines.Add("Intellite updated this computer's skills from the user's Stack at the start of this session; your skill list has them now:") }
    else { [void]$lines.Add("Intellite updated this computer's skills from the user's Stack at the start of this session. New and updated ones join your skill list from the next session; in this session, use each like a skill when its description fits the task: read its SKILL.md first and follow it.") }
    foreach ($change in $skillChanges) {
      $from = ""
      if ($change.organization) { $from = ", from the organization's Stack" }
      if ($change.kind -eq "removed") {
        $why = "taken out of the Stack"
        if ($change.reason -eq "harmful") { $why = "stopped on Intellite as harmful: do not use it, even from earlier in this conversation" }
        elseif ($change.reason -eq "withdrawn") { $why = "taken out of the organization's Stack" }
        elseif ($change.reason -eq "suspended") { $why = "stopped on Intellite" }
        elseif ($change.reason -eq "unavailable") { $why = "no longer readable by the user" }
        elseif ($change.reason -eq "instruction") { $why = "it is an instruction now, given at the start of each session" }
        [void]$lines.Add("- removed $($change.name) ($($change.title)): $why.")
      } else {
        $line = "- $($change.kind) $($change.name) (version $($change.version)$from): $($change.title)"
        if ($Tool -eq "codex") { $line += ". $(Get-Description $change.folder) File: $(Join-Path $change.folder 'SKILL.md')" }
        [void]$lines.Add($line)
      }
    }
    [void]$lines.Add("Tell the user these changes in one short sentence in their language when you first reply.")
  }
  foreach ($note in $Result.notes) { [void]$lines.Add($note) }
  return ($lines -join "`n")
}

# --- connecting ------------------------------------------------------------------------------------------------------------

function Connect-Workspace {
  $BudgetSeconds = 600
  New-Item -ItemType Directory -Force $Root | Out-Null
  $verifier = ConvertTo-Base64Url (Get-RandomBytes 32)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $challenge = ConvertTo-Base64Url $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))
  $state = ConvertTo-Base64Url (Get-RandomBytes 16)
  $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
  $listener.Start()
  try {
    $port = $listener.LocalEndpoint.Port
    $redirect = "http://127.0.0.1:$port/callback"
    $query = @{ response_type = "code"; client_id = $ClientId; redirect_uri = $redirect; scope = $Scope; state = $state; code_challenge = $challenge; code_challenge_method = "S256"; resource = $Resource }
    $url = "$Issuer/oauth/authorize?" + (($query.Keys | ForEach-Object { "$_=" + [Uri]::EscapeDataString($query[$_]) }) -join "&")
    Write-Output "Open this page and approve, choosing your own workspace or an organization:"
    Write-Output $url
    if (-not $NoBrowser) { try { Start-Process $url } catch { } }
    $code = ""
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    while (-not $code -and [DateTime]::UtcNow -lt $deadline) {
      if (-not $listener.Pending()) { Start-Sleep -Milliseconds 200; continue }
      $client = $listener.AcceptTcpClient()
      try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $reader = New-Object System.IO.StreamReader $stream, ([System.Text.Encoding]::ASCII)
        $line = $reader.ReadLine()
        $answer = "Intellite: you can close this tab."
        $status = "200 OK"
        if ($line -match '^GET /callback\?([^ ]*) HTTP') {
          $values = @{}
          foreach ($pair in $Matches[1].Split("&")) { $parts = $pair.Split("=", 2); if ($parts.Count -eq 2) { $values[$parts[0]] = [Uri]::UnescapeDataString($parts[1].Replace("+", " ")) } }
          if ($values["state"] -ne $state) { $answer = "Intellite: this answer was not for this request."; $status = "400 Bad Request" }
          elseif ($values["error"]) { $answer = "Intellite: not connected ($($values['error']))."; $deadline = [DateTime]::UtcNow }
          elseif ($values["code"]) { $code = $values["code"] }
        } else { $status = "404 Not Found"; $answer = "" }
        $bytes = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($answer.Length)`r`nConnection: close`r`n`r`n$answer")
        $stream.Write($bytes, 0, $bytes.Length)
      } catch { } finally { $client.Close() }
    }
  } finally { $listener.Stop() }
  if (-not $code) { throw "Not connected: no approval came back within 5 minutes." }
  $answer = Invoke-Http "POST" "$Issuer/oauth/token" "" @{ grant_type = "authorization_code"; code = $code; redirect_uri = $redirect; client_id = $ClientId; code_verifier = $verifier; resource = $Resource }
  if ($answer.Status -ne 200) {
    $reason = ""
    try { $reason = [string](Get-Field ($answer.Body | ConvertFrom-Json) "error") } catch { }
    throw "Not connected: Intellite answered HTTP $($answer.Status) $reason."
  }
  $token = $answer.Body | ConvertFrom-Json
  $list = Invoke-Http "GET" "$Resource/skills" ([string]$token.access_token)
  if ($list.Status -ne 200) { throw "Connected, but the Stack could not be read (HTTP $($list.Status))." }
  $workspace = ($list.Body | ConvertFrom-Json).workspace
  $label = "the user's own Stack"
  if ($workspace.kind -eq "organization") { $label = "the organization's Stack ($($workspace.id))" }
  $connections = New-Object System.Collections.ArrayList
  # One connection a workspace: connecting it again replaces the earlier one, whose refresh token is revoked.
  foreach ($connection in @(Get-Connections)) {
    if ($connection.workspace -and $connection.workspace.kind -eq $workspace.kind -and $connection.workspace.id -eq $workspace.id) {
      $old = Get-RefreshToken $connection.id
      if ($old) { [void](Invoke-Http "POST" "$Issuer/oauth/revoke" "" @{ token = $old; token_type_hint = "refresh_token"; client_id = $ClientId }) }
      Remove-RefreshToken $connection.id
      Remove-Item -LiteralPath (Get-InstructionsPath $connection.id) -Force -ErrorAction SilentlyContinue
      $connection | Add-Member -NotePropertyName replacedBy -NotePropertyValue "" -Force
      $script:Replaced = $connection.id
      # The folders assigned to the workspace stay with it.
      $script:ReplacedFolders = @(@(Get-Field $connection "folders") | Where-Object { $_ })
      continue
    }
    [void]$connections.Add($connection)
  }
  $id = Get-Hex (Get-RandomBytes 8)
  Save-RefreshToken $id ([string]$token.refresh_token)
  [void]$connections.Add([pscustomobject]@{ id = $id; workspace = $workspace; label = $label; connectedAt = [DateTime]::UtcNow.ToString("o"); ended = $null; folders = @($script:ReplacedFolders | Where-Object { $_ }) })
  Save-Connections $connections
  # Skills an earlier connection of the same workspace brought now belong to this one.
  if ($script:Replaced) {
    foreach ($tool in @("claude", "codex")) {
      $path = Join-Path $Root "state-$tool.json"
      if (-not (Test-Path -LiteralPath $path)) { continue }
      $toolState = Get-State $tool
      foreach ($property in @($toolState.skills.PSObject.Properties)) { if ($property.Value.connection -eq $script:Replaced) { $property.Value.connection = $id } }
      Remove-Entry $toolState.etags $script:Replaced
      Write-Json $path $toolState
    }
  }
  Write-Output "Connected: $label. The skills come into Claude Code and Codex when a session starts."
}

function Disconnect-Workspace([string]$Id) {
  $connections = New-Object System.Collections.ArrayList
  $found = $false
  foreach ($connection in @(Get-Connections)) {
    if ($connection.id -ne $Id) { [void]$connections.Add($connection); continue }
    $found = $true
    $refresh = Get-RefreshToken $connection.id
    $BudgetSeconds = 30
    if ($refresh) { [void](Invoke-Http "POST" "$Issuer/oauth/revoke" "" @{ token = $refresh; token_type_hint = "refresh_token"; client_id = $ClientId }) }
    Remove-RefreshToken $connection.id
    Remove-Item -LiteralPath (Get-InstructionsPath $connection.id) -Force -ErrorAction SilentlyContinue
    foreach ($tool in @("claude", "codex")) {
      $path = Join-Path $Root "state-$tool.json"
      if (-not (Test-Path -LiteralPath $path)) { continue }
      $toolState = Get-State $tool
      $folder = Get-SkillsFolder $tool
      foreach ($property in @($toolState.skills.PSObject.Properties)) {
        if ($property.Value.connection -ne $Id) { continue }
        if (Test-Unchanged (Join-Path $folder $property.Name) $property.Value.files) { Remove-SkillFolder (Join-Path $folder $property.Name) $false }
        Remove-Entry $toolState.skills $property.Name
      }
      Remove-Entry $toolState.etags $Id
      Write-Json $path $toolState
    }
  }
  if (-not $found) { throw "No connection $Id. Run status to see the connections." }
  Save-Connections $connections
  Write-Output "Disconnected $($Id): its skills were taken out (a skill changed on this computer was left in place)."
}

function Set-Folder([string]$Id, [string]$Place, [bool]$Assign) {
  if (-not $Place) { throw "Name the folder: assign <id> <folder>." }
  $full = [System.IO.Path]::GetFullPath($Place).TrimEnd("\")
  $connections = @(Get-Connections)
  $connection = $connections | Where-Object { $_.id -eq $Id } | Select-Object -First 1
  if (-not $connection) { throw "No connection $Id. Run status to see the connections." }
  if (-not ($connection.workspace -and $connection.workspace.kind -eq "organization")) { throw "$Id is the user's own workspace: its instructions are given in every folder." }
  $folders = @(@(Get-Field $connection "folders") | Where-Object { $_ -and $_ -ne $full })
  if ($Assign) { $folders += $full }
  $connection | Add-Member -NotePropertyName folders -NotePropertyValue @($folders) -Force
  Save-Connections $connections
  if ($Assign) { Write-Output "The instructions of $($connection.label) are given in $full and the folders in it." }
  else { Write-Output "The instructions of $($connection.label) are no longer given in $full." }
}

function Show-Status {
  Write-Output "Intellite: $Issuer"
  $connections = @(Get-Connections)
  if ($connections.Count -eq 0) { Write-Output "No connection. Run: intellite-sync connect" }
  foreach ($connection in $connections) {
    $condition = "connected"
    if ($connection.ended) { $condition = "ended (connect again to resume updates)" }
    Write-Output "- $($connection.id): $($connection.label), $condition, last synced $($connection.syncedAt)"
    foreach ($place in @(Get-Field $connection "folders")) { if ($place) { Write-Output "  folder: $place" } }
    foreach ($item in @(Get-Instructions $connection.id)) { Write-Output "  instruction: $($item.name) version $($item.version) ($(([string]$item.text).Length) characters)" }
  }
  foreach ($tool in @("claude", "codex")) {
    $path = Join-Path $Root "state-$tool.json"
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $toolState = Get-State $tool
    foreach ($property in @($toolState.skills.PSObject.Properties)) { Write-Output "  $tool : $($property.Name) version $($property.Value.version)" }
  }
}

# --- one at a time on this computer ----------------------------------------------------------------------------------------

# Claude Code and Codex may start at the same moment; a refresh token used twice ends its connection, so they take turns.
function Enter-Lock([int]$Seconds) {
  New-Item -ItemType Directory -Force $Root | Out-Null
  $until = [DateTime]::UtcNow.AddSeconds($Seconds)
  while ($true) {
    try { return [System.IO.File]::Open((Join-Path $Root "lock"), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None) }
    catch { if ([DateTime]::UtcNow -ge $until) { return $null }; Start-Sleep -Milliseconds 150 }
  }
}

switch ($Command) {
  "hook" {
    # A hook never stops the session: whatever goes wrong, the session starts with the skills as they are.
    try {
      $sessionFolder = Get-SessionFolder
      $lock = Enter-Lock 4
      if ($lock) { try { $result = Sync-Tool $Argument $sessionFolder } finally { $lock.Dispose() } }
      # Another session is syncing: this one is given the instructions last received, and nothing else.
      else { $result = @{ changes = @(); notes = @(); instructions = Get-InstructionText (Get-SessionInstructions $sessionFolder (New-Object System.Collections.ArrayList)) } }
      $text = Get-HookText $Argument $result
      if (-not $text) { exit 0 }
      $output = @{ hookEventName = "SessionStart"; additionalContext = $text }
      if ($Argument -eq "claude" -and $result.changes.Count -gt 0) { $output.reloadSkills = $true }
      [Console]::Out.Write((ConvertTo-AsciiJson @{ hookSpecificOutput = $output }))
    } catch { Write-Log "hook: $($_.Exception.Message)"; exit 0 }
  }
  "connect" { $lock = Enter-Lock 30; try { Connect-Workspace } finally { if ($lock) { $lock.Dispose() } } }
  "disconnect" { $lock = Enter-Lock 30; try { Disconnect-Workspace $Argument } finally { if ($lock) { $lock.Dispose() } } }
  "status" { Show-Status }
  "assign" { $lock = Enter-Lock 30; try { Set-Folder $Argument $Folder $true } finally { if ($lock) { $lock.Dispose() } } }
  "unassign" { $lock = Enter-Lock 30; try { Set-Folder $Argument $Folder $false } finally { if ($lock) { $lock.Dispose() } } }
  default { Write-Output "Usage: intellite-sync hook claude|codex | connect | status | disconnect <id> | assign <id> <folder> | unassign <id> <folder>"; exit 2 }
}
