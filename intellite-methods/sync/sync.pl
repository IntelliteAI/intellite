#!/usr/bin/perl
# Intellite sync for macOS and Linux (Perl and curl).
#   intellite-sync hook claude|codex     SessionStart hook: sync the Stack into the skills folder, print the hook output
#   intellite-sync prompt claude|codex   UserPromptSubmit hook: gives what a sync in the background found, and starts one in the
#                                        background when ten minutes passed (the sh launcher does this without Perl)
#   intellite-sync prompt-run claude|codex  The sync of a prompt, in the background: what changed goes to prompt-<tool>.json
#                                        (instructions: given in full; hook input on stdin, cwd)
#   intellite-sync connect               OAuth 2.0 authorization code, PKCE, loopback redirect; scope methods.stack.read
#   intellite-sync status
#   intellite-sync disconnect <id>       revoke the connection, remove its skills
#   intellite-sync assign <id> <folder>  give an organization's instructions in <folder> (two organizations or more)
#   intellite-sync unassign <id> <folder>
# Refresh tokens: Keychain (macOS), Secret Service (Linux) or a file only this user reads; never printed, logged or put
# on a command line. Same records and output as sync.ps1.
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:flock O_RDWR O_CREAT);
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Temp qw(tempfile);
use IO::Select;
use IO::Socket::INET;
use IPC::Open3 qw(open3);
use JSON::PP;
use MIME::Base64 qw(encode_base64url);
use POSIX qw(strftime);
use Symbol qw(gensym);
use Time::HiRes qw(time sleep);

my $CLIENT_ID = 'intellite-methods-plugin';
my $SCOPE = 'methods.stack.read';
my $STARTED = time;
# A session waits for its start hooks: past this, the session starts with the skills as they are.
my $BUDGET = 10;
# The characters of the instructions given at the start of a session: Claude Code takes up to 10,000 from a hook, and
# what changed and the notes need room too.
my $INSTRUCTION_BUDGET = 8000;
my $JSON = JSON::PP->new->utf8->canonical->pretty;
my $ASCII = JSON::PP->new->ascii->canonical;

my ($command, $argument, @rest) = @ARGV;
$command //= 'status';
$argument //= '';
my $no_browser = grep { $_ eq '--no-browser' || $_ eq '-NoBrowser' } ($argument, @rest);
$argument = '' if $argument eq '--no-browser' || $argument eq '-NoBrowser';

sub issuer {
  my $value = $ENV{INTELLITE_SYNC_ISSUER} // '';
  return 'https://intellite.app' if $value eq '';
  $value =~ s{/+$}{};
  # Intellite, or one on this computer: never another server, which could hand out its own skills.
  return $value if $value eq 'https://intellite.app';
  return $value if $value =~ m{^http://(?:127\.0\.0\.1|localhost):[0-9]{2,5}$};
  die "INTELLITE_SYNC_ISSUER must be https://intellite.app or http://127.0.0.1:<port>.\n";
}
# A start hook never fails a session, not even for a misnamed Intellite: it starts with the skills as they are.
my $ISSUER = eval { issuer() } // do { exit 0 if $command eq 'hook'; die $@ };
my $RESOURCE = "$ISSUER/apps/intellite-methods";
my $HOME = $ENV{HOME} // (getpwuid($<))[7];
(my $place = $ISSUER) =~ s{^https?://}{};
$place =~ s{[^A-Za-z0-9.-]}{-}g;
my $ROOT = File::Spec->catdir($HOME, '.intellite', 'sync', $place);
# INTELLITE_SYNC_STATE, INTELLITE_SYNC_CLAUDE_SKILLS and INTELLITE_SYNC_CODEX_SKILLS override the paths.
$ROOT = $ENV{INTELLITE_SYNC_STATE} if $ENV{INTELLITE_SYNC_STATE};
# The prompt's mark (when the tool last synced) and report (what a sync in the background found), where the sh launcher
# reads them without starting this program.
my $PROMPT_ROOT = $ENV{INTELLITE_SYNC_STATE} || File::Spec->catdir($HOME, '.intellite', 'sync');
sub prompt_file { my ($tool, $kind) = @_; return File::Spec->catfile($PROMPT_ROOT, "prompt-$tool.$kind"); }
sub set_prompt_mark { my ($tool) = @_; make_path($PROMPT_ROOT) unless -d $PROMPT_ROOT; if (open(my $fh, '>', prompt_file($tool, 'mark'))) { close $fh; } }

sub skills_folder {
  my ($tool) = @_;
  return $ENV{INTELLITE_SYNC_CLAUDE_SKILLS} if $tool eq 'claude' && $ENV{INTELLITE_SYNC_CLAUDE_SKILLS};
  return $ENV{INTELLITE_SYNC_CODEX_SKILLS} if $tool eq 'codex' && $ENV{INTELLITE_SYNC_CODEX_SKILLS};
  if ($tool eq 'claude') {
    return File::Spec->catdir($ENV{CLAUDE_CONFIG_DIR}, 'skills') if $ENV{CLAUDE_CONFIG_DIR};
    return File::Spec->catdir($HOME, '.claude', 'skills');
  }
  return File::Spec->catdir($HOME, '.agents', 'skills') if $tool eq 'codex';
  die "The AI tool is claude or codex.\n";
}

# --- small helpers -----------------------------------------------------------------------------------------------------

sub now_iso { return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime) }
sub seconds_left { return $BUDGET - (time - $STARTED) }
sub random_bytes {
  my ($count) = @_;
  open(my $fh, '<:raw', '/dev/urandom') or die "No /dev/urandom.\n";
  my $bytes = '';
  read($fh, $bytes, $count) == $count or die "Could not read random bytes.\n";
  close $fh;
  return $bytes;
}
sub read_bytes {
  my ($path) = @_;
  open(my $fh, '<:raw', $path) or return undef;
  local $/;
  my $bytes = <$fh>;
  close $fh;
  return $bytes // '';
}
sub write_bytes {
  my ($path, $bytes, $mode) = @_;
  my $temp = "$path." . unpack('H*', random_bytes(6)) . '.tmp';
  open(my $fh, '>:raw', $temp) or die "Could not write $temp.\n";
  chmod($mode, $temp) if defined $mode;
  print $fh $bytes;
  close $fh or die "Could not write $temp.\n";
  rename($temp, $path) or die "Could not put $path in place.\n";
}
sub read_json {
  my ($path, $default) = @_;
  my $bytes = read_bytes($path);
  return $default unless defined $bytes && length $bytes;
  my $value = eval { $JSON->decode($bytes) };
  return defined $value ? $value : $default;
}
sub write_json { my ($path, $value) = @_; write_bytes($path, $JSON->encode($value)) }
sub decode_json_text { my ($bytes) = @_; return eval { JSON::PP->new->utf8->decode($bytes // '') } }
sub is_link { my ($path) = @_; return -l $path }
sub ensure_dir { my ($path) = @_; make_path($path) unless -d $path; }
sub log_line {
  my ($text) = @_;
  eval {
    my $path = File::Spec->catfile($ROOT, 'sync.log');
    my @lines = ();
    if (open(my $fh, '<:encoding(UTF-8)', $path)) { @lines = <$fh>; close $fh; }
    @lines = @lines[-199 .. -1] if @lines > 199;
    open(my $out, '>:encoding(UTF-8)', $path) or return;
    print $out @lines, now_iso() . " $text\n";
    close $out;
  };
}

# A program given its input on its standard input, whose output is read back and whose errors are dropped:
# (exit code, output). 127 when it could not be started.
sub run_program {
  my ($input, @command) = @_;
  my ($in, $out, $error) = (undef, undef, gensym);
  my $pid = eval { open3($in, $out, $error, @command) };
  return (127, '') unless $pid;
  print $in $input if length $input;
  close $in;
  my $text = do { local $/; <$out> } // '';
  close $out;
  { local $/; my $dropped = <$error>; }
  waitpid($pid, 0);
  return ($? >> 8, $text);
}

# --- HTTP, through curl: the request's secrets go to curl on its standard input, never on its command line -------------

sub curl_quote { my ($value) = @_; $value =~ s/(["\\])/\\$1/g; $value =~ s/\n/\\n/g; return "\"$value\""; }
# After one request that reached nothing, the rest of this run does not wait again: the session starts as it is.
my $offline = 0;
sub http {
  my ($method, $url, %option) = @_;
  my $left = seconds_left();
  return { status => 0, body => '', etag => '' } if $offline || $left <= 0;
  my $time = $left < 5 ? $left : 5;
  $time = 1 if $time < 1;
  my ($body_fh, $body_path) = tempfile(DIR => $ROOT, UNLINK => 1);
  my ($head_fh, $head_path) = tempfile(DIR => $ROOT, UNLINK => 1);
  close $body_fh; close $head_fh;
  my @config = ('url = ' . curl_quote($url), 'request = ' . curl_quote($method), 'header = "Accept: application/json"',
    'user-agent = "intellite-sync/1 (Perl)"', 'output = ' . curl_quote($body_path), 'dump-header = ' . curl_quote($head_path),
    'write-out = "%{http_code}"', 'silent', sprintf('max-time = %d', $time), 'connect-timeout = 4');
  push @config, 'header = ' . curl_quote("Authorization: Bearer $option{token}") if $option{token};
  push @config, 'header = ' . curl_quote("If-None-Match: $option{etag}") if $option{etag};
  if ($option{form}) {
    for my $key (sort keys %{ $option{form} }) { push @config, 'data-urlencode = ' . curl_quote("$key=$option{form}{$key}"); }
  }
  # curl reads its whole configuration, the token included, from its standard input.
  my (undef, $code) = run_program(join("\n", @config) . "\n", 'curl', '-K', '-');
  my $status = $code =~ /^([0-9]{3})$/ ? $1 + 0 : 0;
  $offline = 1 if $status == 0;
  my $etag = '';
  if (my $headers = read_bytes($head_path)) { ($etag) = $headers =~ /^etag:\s*(.+?)\s*$/mi; $etag //= ''; }
  my $body = read_bytes($body_path) // '';
  unlink $body_path, $head_path;
  return { status => $status, body => $body, etag => $etag };
}

# --- connections and their refresh tokens --------------------------------------------------------------------------------

sub connections { my $list = read_json(File::Spec->catfile($ROOT, 'connections.json'), []); return ref $list eq 'ARRAY' ? $list : [$list]; }
sub save_connections { my ($list) = @_; write_json(File::Spec->catfile($ROOT, 'connections.json'), $list); }
sub have { my ($program) = @_; for my $dir (split /:/, $ENV{PATH} // '') { return 1 if -x File::Spec->catfile($dir, $program); } return 0; }
sub run_quiet { return run_program(@_); }
my $SERVICE = "intellite-sync:$place";
sub secret_file { my ($id) = @_; return File::Spec->catfile($ROOT, "$id.secret"); }
# Where a connection's refresh token is kept: the keychain (macOS), the Secret Service (Linux), or a file of this user's.
sub save_refresh_token {
  my ($connection, $token) = @_;
  my $id = $connection->{id};
  # Each store is read back before it counts: a store that took nothing would end the connection at its next use.
  if ($^O eq 'darwin' && have('security')) {
    run_quiet("add-generic-password -U -s $SERVICE -a $id -l \"Intellite sync\" -w \"$token\"\n", 'security', '-i');
    $connection->{store} = 'keychain';
    if (refresh_token($connection) eq $token) { unlink secret_file($id); return; }
  }
  if ($^O ne 'darwin' && have('secret-tool')) {
    run_quiet($token, 'secret-tool', 'store', '--label=Intellite sync', 'service', $SERVICE, 'account', $id);
    $connection->{store} = 'secret-service';
    if (refresh_token($connection) eq $token) { unlink secret_file($id); return; }
  }
  write_bytes(secret_file($id), $token, 0600);
  $connection->{store} = 'file';
}
sub refresh_token {
  my ($connection) = @_;
  my $id = $connection->{id};
  my $store = $connection->{store} // 'file';
  if ($store eq 'keychain') { my ($code, $text) = run_quiet('', 'security', 'find-generic-password', '-s', $SERVICE, '-a', $id, '-w'); chomp $text; return $code == 0 ? $text : ''; }
  if ($store eq 'secret-service') { my ($code, $text) = run_quiet('', 'secret-tool', 'lookup', 'service', $SERVICE, 'account', $id); chomp $text; return $code == 0 ? $text : ''; }
  return read_bytes(secret_file($id)) // '';
}
sub remove_refresh_token {
  my ($connection) = @_;
  my $id = $connection->{id};
  run_quiet('', 'security', 'delete-generic-password', '-s', $SERVICE, '-a', $id) if ($connection->{store} // '') eq 'keychain';
  run_quiet('', 'secret-tool', 'clear', 'service', $SERVICE, 'account', $id) if ($connection->{store} // '') eq 'secret-service';
  unlink secret_file($id);
}

# An access token for a connection, from its refresh token, which is replaced at once by the new one (each is used once).
# Returns ('', 1) when Intellite says the connection is over, and ('', 0) when it could not be reached.
sub access_token {
  my ($connection) = @_;
  my $refresh = refresh_token($connection);
  return ('', 1) unless $refresh;
  my $answer = http('POST', "$ISSUER/oauth/token", form => { grant_type => 'refresh_token', refresh_token => $refresh, client_id => $CLIENT_ID, resource => $RESOURCE });
  if ($answer->{status} == 200) {
    my $token = decode_json_text($answer->{body}) // {};
    save_refresh_token($connection, $token->{refresh_token}) if $token->{refresh_token};
    return ($token->{access_token} // '', 0);
  }
  return ('', ($answer->{status} == 400 || $answer->{status} == 401) ? 1 : 0);
}

# --- the instructions each connection gave ------------------------------------------------------------------------------

sub instructions_path { my ($id) = @_; return File::Spec->catfile($ROOT, "instructions-$id.json"); }
sub instructions_of { my ($id) = @_; my $list = read_json(instructions_path($id), []); return ref $list eq 'ARRAY' ? $list : []; }
sub utf8_sha { my ($text) = @_; my $bytes = $text // ''; utf8::encode($bytes); return sha256_hex($bytes); }
# Keeps what the list gave, each checked against its SHA-256: a text that does not match is not kept.
sub save_instructions {
  my ($id, $list) = @_;
  my @kept;
  for my $item (@{ $list // [] }) {
    if (utf8_sha($item->{text}) ne ($item->{sha256} // '')) { log_line("instruction $item->{name} $item->{version}: the text does not match its SHA-256"); next; }
    push @kept, { map { ($_ => $item->{$_}) } qw(name methodId version title organization digest text) };
  }
  write_json(instructions_path($id), \@kept);
}

# The folder the session works in, from the hook's input on stdin (Claude Code and Codex send its cwd). Read for at most
# a second and a half, so that a hook started without input does not wait.
sub session_folder {
  return '' if -t STDIN;
  my $select = IO::Select->new(\*STDIN);
  my ($raw, $until) = ('', time + 1.5);
  while (time < $until) {
    last unless $select->can_read($until - time);
    my $got = sysread(STDIN, my $chunk, 65536);
    last unless $got;
    $raw .= $chunk;
  }
  my $input = decode_json_text($raw);
  return ref $input eq 'HASH' ? ($input->{cwd} // '') : '';
}
sub within {
  my ($place, $parent) = @_;
  return 0 unless length($place // '') && length($parent // '');
  my ($child, $root) = map { my $path = File::Spec->rel2abs($_); $path =~ s{/+$}{}; "$path/" } ($place, $parent);
  ($child, $root) = (lc $child, lc $root) if $^O eq 'darwin';
  return index($child, $root) == 0;
}

# The instructions for a session in that folder: an organization's first, then the user's own. An organization's are
# given everywhere while it is the only organization connected and no folder is assigned to it; otherwise only in the
# folders assigned to it, so that one organization's instructions never reach another's work.
sub session_instructions {
  my ($folder, $notes) = @_;
  my $connections = connections();
  my $is_organization = sub { my ($connection) = @_; return ($connection->{workspace} && ($connection->{workspace}{kind} // '') eq 'organization') ? 1 : 0; };
  my @organizations = grep { $is_organization->($_) } @$connections;
  my (@given, @withheld);
  for my $connection (@organizations, grep { !$is_organization->($_) } @$connections) {
    my $items = instructions_of($connection->{id});
    next unless @$items;
    if ($is_organization->($connection)) {
      my @folders = grep { length($_ // '') } @{ $connection->{folders} // [] };
      my $applies = 0;
      if (@folders) { $applies = 1 if grep { within($folder, $_) } @folders; }
      elsif (@organizations == 1) { $applies = 1; }
      else { push @withheld, $connection; }
      next unless $applies;
    }
    push @given, @$items;
  }
  if (@withheld) {
    my $ids = join(', ', map { "$_->{id} ($_->{label})" } @withheld);
    push @$notes, { key => 'unassigned', daily => 1, text => "Intellite: the instructions of $ids are not given in this session, because more than one organization is connected and this folder is not assigned to one of them. When the user works for one of them here, with their consent, run: " . program_command() . ' assign <id> "<folder>"' };
  }
  return \@given;
}

sub instruction_text {
  my ($items) = @_;
  return '' unless @$items;
  my @lines = ("Intellite: the instructions the user's organization and the user keep on Intellite for all their work with AI tools, given at the start of every session. They apply to everything in this session, not only to the work they name. Where the user's own differ from the organization's, the organization's apply.");
  my ($used, @left) = (0);
  for my $item (@$items) {
    my $text = $item->{text} // '';
    if ($used + length($text) > $INSTRUCTION_BUDGET) { push @left, "$item->{title} (version $item->{version})"; next; }
    $used += length $text;
    my $from = $item->{organization} ? 'From the organization' : "The user's own";
    push @lines, '', "## $from: $item->{title} (version $item->{version})", $text;
  }
  push @lines, '', 'Not given here, as the instructions above already fill what a session is given at its start: ' . join(', ', @left) . '. Read them on Intellite when the work needs them.' if @left;
  return join("\n", @lines);
}

# --- what is kept: the record of each AI tool's skills ------------------------------------------------------------------

sub state_path { my ($tool) = @_; return File::Spec->catfile($ROOT, "state-$tool.json"); }
sub load_state {
  my ($tool) = @_;
  my $state = read_json(state_path($tool), {});
  $state = {} unless ref $state eq 'HASH';
  for my $name (qw(skills etags pins notices)) { $state->{$name} = {} unless ref $state->{$name} eq 'HASH'; }
  return $state;
}
sub file_sha { my ($path) = @_; my $bytes = read_bytes($path); return defined $bytes ? sha256_hex($bytes) : ''; }
# The files of a kept skill as they are now, compared with what was written: true when every one is unchanged.
sub unchanged {
  my ($folder, $files) = @_;
  return 0 unless -d $folder && !is_link($folder);
  for my $name (keys %{ $files // {} }) {
    my $path = File::Spec->catfile($folder, $name);
    return 0 unless -f $path && !is_link($path) && file_sha($path) eq $files->{$name};
  }
  return 1;
}
# Takes a kept skill's folder out: into the record's folder of removed skills when it was stopped as harmful (so nothing
# is lost), deleted otherwise. Only a real folder, never a link.
sub remove_skill_folder {
  my ($folder, $keep) = @_;
  return unless -e $folder;
  return if is_link($folder);
  if ($keep) {
    my $removed = File::Spec->catdir($ROOT, 'removed');
    ensure_dir($removed);
    my (undef, undef, $leaf) = File::Spec->splitpath($folder);
    rename($folder, File::Spec->catdir($removed, strftime('%Y%m%d%H%M%S', gmtime) . "-$leaf")) or remove_tree($folder);
  } else { remove_tree($folder); }
}

# Writes the files of one version into a new folder beside the skills, checks each against its SHA-256 and the version's
# pin, and then puts the folder in place of the skill's. Returns '' when done, or why it was not.
sub install_skill {
  my ($skills_folder, $skill, $bundle, $state) = @_;
  my $name = $skill->{name} // '';
  return 'its name is not an Intellite skill name' unless $name =~ /^intellite-[a-z0-9]+(?:-[a-z0-9]+)*$/;
  my $pin_key = "$skill->{methodId}\@$skill->{version}";
  my $pin = $state->{pins}{$pin_key};
  my %files;
  my $temp = File::Spec->catdir($skills_folder, '.intellite-new-' . unpack('H*', random_bytes(8)));
  ensure_dir($temp);
  my $why = eval {
    for my $file (@{ $bundle->{files} // [] }) {
      my $path = $file->{path} // '';
      return 'it carries a file other than SKILL.md and intellite-method.json' unless $path eq 'SKILL.md' || $path eq 'intellite-method.json';
      my $bytes = $file->{text} // '';
      utf8::encode($bytes);
      my $sha = sha256_hex($bytes);
      return "$path does not match its SHA-256" unless $sha eq ($file->{sha256} // '');
      return "version $skill->{version} came with other content than before (a published version never changes)" if $pin && $pin->{$path} && $pin->{$path} ne $sha;
      write_bytes(File::Spec->catfile($temp, $path), $bytes);
      $files{$path} = $sha;
    }
    return 'it has no SKILL.md' unless $files{'SKILL.md'};
    my $target = File::Spec->catdir($skills_folder, $name);
    if (-e $target) {
      return "$target is a link" if is_link($target);
      my $kept = $state->{skills}{$name};
      if (!$kept) {
        # A folder this program did not write: replaced only when its SKILL.md names the same post.
        my $skill_file = File::Spec->catfile($target, 'SKILL.md');
        my $text = (-f $skill_file && !is_link($skill_file)) ? (read_bytes($skill_file) // '') : '';
        my $id = quotemeta($skill->{methodId});
        return 'a folder of that name is already there and is not this post\'s' unless $text =~ /^\s*intellite-method-id:\s*"$id"\s*$/m;
      } elsif (!unchanged($target, $kept->{files})) {
        return 'it was changed on this computer, so it was left as it is';
      }
      my $old = File::Spec->catdir($skills_folder, '.intellite-old-' . unpack('H*', random_bytes(8)));
      rename($target, $old) or return 'the old folder could not be moved';
      rename($temp, $target) or do { rename($old, $target); return 'the new folder could not be put in place'; };
      remove_tree($old);
    } else {
      rename($temp, $target) or return 'the new folder could not be put in place';
    }
    $state->{pins}{$pin_key} = { %files };
    $state->{skills}{$name} = { connection => $skill->{connection}, methodId => $skill->{methodId}, version => $skill->{version}, title => $skill->{title},
      organization => $skill->{organization} ? JSON::PP::true : JSON::PP::false, digest => ($bundle->{method}{digest} // ''), files => { %files } };
    return '';
  };
  $why = "it could not be written ($@)" unless defined $why;
  remove_tree($temp) if -d $temp;
  return $why;
}

sub description_of {
  my ($folder) = @_;
  my $text = read_bytes(File::Spec->catfile($folder, 'SKILL.md')) // '';
  return '' unless $text =~ /^description:\s*(".*")\s*$/m;
  my $value = eval { JSON::PP->new->allow_nonref->decode($1) };
  return defined $value ? $value : '';
}

sub program_command {
  my $here = (File::Spec->splitpath(File::Spec->rel2abs(__FILE__)))[1];
  $here =~ s{/+$}{};
  return "\"$here/intellite-sync\"";
}
sub connect_command { return program_command() . ' connect'; }

# --- one sync of one AI tool's skills -------------------------------------------------------------------------------------

sub sync_tool {
  my ($tool, $session_folder) = @_;
  my $skills_folder = skills_folder($tool);
  ensure_dir($skills_folder);
  my $state = load_state($tool);
  my $connections = connections();
  my (@changes, @notes);
  my $now = now_iso();

  for my $connection (@$connections) {
    next if $connection->{ended};
    my ($access, $ended) = access_token($connection);
    if (!$access) { $connection->{ended} = $now if $ended; next; }
    my $etag = $state->{etags}{$connection->{id}} // '';
    # Kept unchanged when a version could not be put in place, so that the next session tries again.
    my $complete = 1;
    my $answer = http('GET', "$RESOURCE/skills", token => $access, etag => $etag);
    next if $answer->{status} == 304;
    if ($answer->{status} != 200) {
      # Refused by the organization's rules (a network or sign-in rule): nothing is taken out, the AI is told once a day.
      if ($answer->{status} == 401 || $answer->{status} == 403) {
        my $message = (decode_json_text($answer->{body}) // {})->{message} // '';
        push @notes, { key => "refused-$connection->{id}", daily => 1, text => "Intellite refused the update of the skills from $connection->{label} (HTTP $answer->{status}): $message The skills already here stay as they are." };
      }
      log_line("list of $connection->{id}: HTTP $answer->{status}");
      next;
    }
    my $list = decode_json_text($answer->{body}) // {};
    save_instructions($connection->{id}, $list->{instructions});
    my %wanted;
    for my $skill (@{ $list->{skills} // [] }) {
      $skill->{connection} = $connection->{id};
      $wanted{$skill->{name}} = $skill;
      my $kept = $state->{skills}{$skill->{name}};
      next if $kept && ($kept->{connection} // '') ne $connection->{id};
      my $folder = File::Spec->catdir($skills_folder, $skill->{name});
      next if $kept && $kept->{version} == $skill->{version} && unchanged($folder, $kept->{files});
      my $files = http('GET', "$RESOURCE/skills/$skill->{methodId}/$skill->{version}", token => $access);
      if ($files->{status} != 200) { $complete = 0; log_line("files of $skill->{name} $skill->{version}: HTTP $files->{status}"); next; }
      my $why = install_skill($skills_folder, $skill, decode_json_text($files->{body}) // {}, $state);
      if ($why) {
        push @notes, { key => "skip-$skill->{name}-$skill->{version}", text => "Intellite did not put $skill->{name} version $skill->{version} in place: $why." };
        $complete = 0;
        log_line("$skill->{name} $skill->{version} not put in place: $why");
        next;
      }
      push @changes, { kind => ($kept ? 'updated' : 'added'), name => $skill->{name}, version => $skill->{version}, title => $skill->{title}, organization => $skill->{organization} ? 1 : 0, folder => $folder };
    }
    # Taken out: what the list says to take out, and what this connection brought that the list no longer gives.
    my %reasons = map { ($_->{name} => $_->{reason}) } @{ $list->{remove} // [] };
    # A post whose version chosen is an instruction now leaves the skills: it is given at the start of each session.
    $reasons{ $_->{name} } = 'instruction' for @{ $list->{instructions} // [] };
    for my $name (sort keys %{ $state->{skills} }) {
      my $kept = $state->{skills}{$name};
      next if ($kept->{connection} // '') ne $connection->{id} || $wanted{$name};
      my $reason = $reasons{$name} // 'removed';
      my $folder = File::Spec->catdir($skills_folder, $name);
      if ($reason ne 'harmful' && -e $folder && !unchanged($folder, $kept->{files})) {
        push @notes, { key => "left-$name", text => "Intellite no longer gives $name, but it was changed on this computer, so it was left in place." };
        delete $state->{skills}{$name};
        next;
      }
      remove_skill_folder($folder, $reason eq 'harmful');
      delete $state->{skills}{$name};
      push @changes, { kind => 'removed', name => $name, reason => $reason, title => $kept->{title} };
    }
    $state->{etags}{$connection->{id}} = $complete ? $answer->{etag} : '';
    $connection->{syncedAt} = $now;
    $connection->{workspace} = $list->{workspace};
  }

  # Versions stopped as harmful are taken out even without a connection: the list is public and names digests only.
  my $instructions_kept = grep { @{ instructions_of($_->{id}) } } @$connections;
  if (%{ $state->{skills} } || $instructions_kept) {
    my $stopped = http('GET', "$RESOURCE/skills/stopped", etag => ($state->{notices}{stoppedETag} // ''));
    if ($stopped->{status} == 200) {
      my %harmful = map { ($_ => 1) } @{ (decode_json_text($stopped->{body}) // {})->{harmful} // [] };
      for my $connection (@$connections) {
        my $items = instructions_of($connection->{id});
        my @keep = grep { !($_->{digest} && $harmful{ $_->{digest} }) } @$items;
        next if @keep == @$items;
        push @changes, map { { kind => 'removed', name => $_->{name}, reason => 'harmful', title => $_->{title}, instruction => 1 } } grep { $_->{digest} && $harmful{ $_->{digest} } } @$items;
        write_json(instructions_path($connection->{id}), \@keep);
      }
      for my $name (sort keys %{ $state->{skills} }) {
        my $kept = $state->{skills}{$name};
        next unless $kept->{digest} && $harmful{$kept->{digest}};
        remove_skill_folder(File::Spec->catdir($skills_folder, $name), 1);
        delete $state->{skills}{$name};
        push @changes, { kind => 'removed', name => $name, reason => 'harmful', title => $kept->{title} };
      }
      $state->{notices}{stoppedETag} = $stopped->{etag};
    }
  }

  # Ended connections: the AI is told once a day, with what to run to connect again.
  for my $connection (@$connections) {
    next unless $connection->{ended};
    push @notes, { key => "ended-$connection->{id}", daily => 1, text => "Intellite: updates of the skills from $connection->{label} stopped on this computer, because the connection ended (it ends after a time without use, or when it is stopped on Intellite). The skills already here stay and work at their versions. To resume, with the user's consent, run: " . connect_command() };
  }
  if (!@$connections && !$state->{notices}{offered}) {
    push @notes, { key => 'offered', text => "Intellite can keep the user's Stack (the methods the user and their organization chose on Intellite) among this computer's skills, so that you use them without the user naming Intellite. It is not connected on this computer. When the user works with Intellite, offer it once; with their consent, run: " . connect_command() . " (it opens Intellite's consent page in the browser, where the user chooses their own workspace or an organization, and waits up to 5 minutes)." };
  }

  save_connections($connections);
  my $instructions = instruction_text(session_instructions($session_folder, \@notes));
  my @told;
  for my $note (@notes) {
    my $last = $state->{notices}{ $note->{key} };
    next if $last && (!$note->{daily} || hours_since($last) < 20);
    $state->{notices}{ $note->{key} } = $now;
    push @told, $note->{text};
  }
  write_json(state_path($tool), $state);
  # When this tool last synced: a prompt starts another sync only PROMPT_MINUTES after it.
  set_prompt_mark($tool);
  return { changes => \@changes, notes => \@told, instructions => $instructions };
}

sub hours_since {
  my ($iso) = @_;
  return 1e9 unless $iso =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)/;
  require Time::Local;
  my $then = eval { Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1) } // 0;
  return (time - $then) / 3600;
}

# How long a prompt-time check waits after the last sync of a tool before it syncs again.
my $PROMPT_MINUTES = 10;
sub hook_text {
  my ($tool, $result, $moment) = @_;
  $moment //= 'at the start of this session';
  my @lines;
  push @lines, $result->{instructions}, '' if length($result->{instructions} // '');
  my @skill_changes = grep { !$_->{instruction} } @{ $result->{changes} };
  push @lines, "Intellite stopped the instruction $_->{name} ($_->{title}) as harmful: do not follow it, even from earlier in this conversation." for grep { $_->{instruction} } @{ $result->{changes} };
  if (@skill_changes) {
    push @lines, $tool eq 'claude'
      ? "Intellite updated this computer's skills from the user's Stack $moment; your skill list has them now:"
      : "Intellite updated this computer's skills from the user's Stack $moment. New and updated ones join your skill list from the next session; in this session, use each like a skill when its description fits the task: read its SKILL.md first and follow it.";
    for my $change (@skill_changes) {
      my $from = $change->{organization} ? ", from the organization's Stack" : '';
      if ($change->{kind} eq 'removed') {
        my %why = (harmful => 'stopped on Intellite as harmful: do not use it, even from earlier in this conversation', withdrawn => "taken out of the organization's Stack",
          suspended => 'stopped on Intellite', unavailable => 'no longer readable by the user', instruction => 'it is an instruction now, given at the start of each session');
        push @lines, "- removed $change->{name} ($change->{title}): " . ($why{ $change->{reason} } // 'taken out of the Stack') . '.';
      } else {
        my $line = "- $change->{kind} $change->{name} (version $change->{version}$from): $change->{title}";
        $line .= '. ' . description_of($change->{folder}) . ' File: ' . File::Spec->catfile($change->{folder}, 'SKILL.md') if $tool eq 'codex';
        push @lines, $line;
      }
    }
    push @lines, 'Tell the user these changes in one short sentence in their language when you first reply.';
  }
  push @lines, @{ $result->{notes} };
  return join("\n", @lines);
}

# --- connecting ------------------------------------------------------------------------------------------------------------

sub connect_workspace {
  $BUDGET = 600;
  ensure_dir($ROOT);
  my $verifier = encode_base64url(random_bytes(32));
  my $challenge = encode_base64url(Digest::SHA::sha256($verifier));
  my $state_value = encode_base64url(random_bytes(16));
  my $listener = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, Proto => 'tcp', ReuseAddr => 1) or die "Could not listen on this computer.\n";
  my $port = $listener->sockport;
  my $redirect = "http://127.0.0.1:$port/callback";
  my %query = (response_type => 'code', client_id => $CLIENT_ID, redirect_uri => $redirect, scope => $SCOPE, state => $state_value,
    code_challenge => $challenge, code_challenge_method => 'S256', resource => $RESOURCE);
  my $escape = sub { my ($value) = @_; $value =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord $1)/ge; return $value; };
  my $url = "$ISSUER/oauth/authorize?" . join('&', map { "$_=" . $escape->($query{$_}) } sort keys %query);
  print "Open this page and approve, choosing your own workspace or an organization:\n$url\n";
  STDOUT->flush;
  if (!$no_browser) {
    my $opener = $^O eq 'darwin' ? 'open' : 'xdg-open';
    if (have($opener)) { my $pid = fork(); if (defined $pid && $pid == 0) { open(STDOUT, '>', File::Spec->devnull); open(STDERR, '>', File::Spec->devnull); exec($opener, $url); exit 0; } }
  }
  my ($code, $deadline) = ('', time + 300);
  my $select = IO::Select->new($listener);
  while (!$code && time < $deadline) {
    next unless $select->can_read(0.5);
    my $client = $listener->accept or next;
    my $line = '';
    my $client_select = IO::Select->new($client);
    if ($client_select->can_read(5)) { $line = <$client> // ''; }
    my ($status, $answer) = ('404 Not Found', '');
    if ($line =~ m{^GET /callback\?(\S*) HTTP}) {
      my %values;
      for my $pair (split /&/, $1) { my ($key, $value) = split /=/, $pair, 2; next unless defined $value; $value =~ tr/+/ /; $value =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge; $values{$key} = $value; }
      ($status, $answer) = ('200 OK', 'Intellite: you can close this tab.');
      if (($values{state} // '') ne $state_value) { ($status, $answer) = ('400 Bad Request', 'Intellite: this answer was not for this request.'); }
      elsif ($values{error}) { $answer = "Intellite: not connected ($values{error})."; $deadline = 0; }
      elsif ($values{code}) { $code = $values{code}; }
    }
    print $client "HTTP/1.1 $status\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: " . length($answer) . "\r\nConnection: close\r\n\r\n$answer";
    close $client;
  }
  close $listener;
  die "Not connected: no approval came back within 5 minutes.\n" unless $code;
  my $answer = http('POST', "$ISSUER/oauth/token", form => { grant_type => 'authorization_code', code => $code, redirect_uri => $redirect, client_id => $CLIENT_ID, code_verifier => $verifier, resource => $RESOURCE });
  if ($answer->{status} != 200) { my $reason = (decode_json_text($answer->{body}) // {})->{error} // ''; die "Not connected: Intellite answered HTTP $answer->{status} $reason.\n"; }
  my $token = decode_json_text($answer->{body}) // {};
  my $list = http('GET', "$RESOURCE/skills", token => $token->{access_token});
  die "Connected, but the Stack could not be read (HTTP $list->{status}).\n" unless $list->{status} == 200;
  my $workspace = (decode_json_text($list->{body}) // {})->{workspace} // {};
  my $label = ($workspace->{kind} // '') eq 'organization' ? "the organization's Stack ($workspace->{id})" : "the user's own Stack";
  my (@kept, $replaced, @folders);
  # One connection a workspace: connecting it again replaces the earlier one, whose refresh token is revoked.
  for my $connection (@{ connections() }) {
    my $same = $connection->{workspace} && ($connection->{workspace}{kind} // '') eq ($workspace->{kind} // '') && ($connection->{workspace}{id} // '') eq ($workspace->{id} // '');
    if ($same) {
      my $old = refresh_token($connection);
      http('POST', "$ISSUER/oauth/revoke", form => { token => $old, token_type_hint => 'refresh_token', client_id => $CLIENT_ID }) if $old;
      remove_refresh_token($connection);
      unlink instructions_path($connection->{id});
      $replaced = $connection->{id};
      # The folders assigned to the workspace stay with it.
      @folders = grep { length($_ // '') } @{ $connection->{folders} // [] };
      next;
    }
    push @kept, $connection;
  }
  my $connection = { id => unpack('H*', random_bytes(8)), workspace => $workspace, label => $label, connectedAt => now_iso(), ended => undef, folders => \@folders };
  save_refresh_token($connection, $token->{refresh_token});
  push @kept, $connection;
  save_connections(\@kept);
  # Skills an earlier connection of the same workspace brought now belong to this one.
  if ($replaced) {
    for my $tool (qw(claude codex)) {
      next unless -f state_path($tool);
      my $tool_state = load_state($tool);
      for my $kept (values %{ $tool_state->{skills} }) { $kept->{connection} = $connection->{id} if ($kept->{connection} // '') eq $replaced; }
      delete $tool_state->{etags}{$replaced};
      write_json(state_path($tool), $tool_state);
    }
  }
  print "Connected: $label. The skills come into Claude Code and Codex when a session starts.\n";
}

sub disconnect_workspace {
  my ($id) = @_;
  $BUDGET = 30;
  my (@kept, $found);
  for my $connection (@{ connections() }) {
    if (($connection->{id} // '') ne $id) { push @kept, $connection; next; }
    $found = 1;
    my $refresh = refresh_token($connection);
    http('POST', "$ISSUER/oauth/revoke", form => { token => $refresh, token_type_hint => 'refresh_token', client_id => $CLIENT_ID }) if $refresh;
    remove_refresh_token($connection);
    unlink instructions_path($connection->{id});
    for my $tool (qw(claude codex)) {
      next unless -f state_path($tool);
      my $tool_state = load_state($tool);
      my $folder = skills_folder($tool);
      for my $name (keys %{ $tool_state->{skills} }) {
        my $skill = $tool_state->{skills}{$name};
        next unless ($skill->{connection} // '') eq $id;
        my $path = File::Spec->catdir($folder, $name);
        remove_skill_folder($path, 0) if unchanged($path, $skill->{files});
        delete $tool_state->{skills}{$name};
      }
      delete $tool_state->{etags}{$id};
      write_json(state_path($tool), $tool_state);
    }
  }
  die "No connection $id. Run status to see the connections.\n" unless $found;
  save_connections(\@kept);
  print "Disconnected $id: its skills were taken out (a skill changed on this computer was left in place).\n";
}

sub set_folder {
  my ($id, $place, $assign) = @_;
  die "Name the folder: assign <id> <folder>.\n" unless length($place // '');
  my $full = File::Spec->rel2abs($place);
  $full =~ s{/+$}{};
  my $list = connections();
  my ($connection) = grep { ($_->{id} // '') eq $id } @$list;
  die "No connection $id. Run status to see the connections.\n" unless $connection;
  die "$id is the user's own workspace: its instructions are given in every folder.\n" unless $connection->{workspace} && ($connection->{workspace}{kind} // '') eq 'organization';
  my @folders = grep { length($_ // '') && $_ ne $full } @{ $connection->{folders} // [] };
  push @folders, $full if $assign;
  $connection->{folders} = \@folders;
  save_connections($list);
  print $assign ? "The instructions of $connection->{label} are given in $full and the folders in it.\n" : "The instructions of $connection->{label} are no longer given in $full.\n";
}

sub show_status {
  print "Intellite: $ISSUER\n";
  my $list = connections();
  print "No connection. Run: intellite-sync connect\n" unless @$list;
  for my $connection (@$list) {
    my $condition = $connection->{ended} ? 'ended (connect again to resume updates)' : 'connected';
    printf "- %s: %s, %s, last synced %s\n", $connection->{id}, $connection->{label}, $condition, $connection->{syncedAt} // '-';
    print "  folder: $_\n" for grep { length($_ // '') } @{ $connection->{folders} // [] };
    printf "  instruction: %s version %s (%d characters)\n", $_->{name}, $_->{version}, length($_->{text} // '') for @{ instructions_of($connection->{id}) };
  }
  for my $tool (qw(claude codex)) {
    next unless -f state_path($tool);
    my $tool_state = load_state($tool);
    printf "  %s : %s version %s\n", $tool, $_, $tool_state->{skills}{$_}{version} for sort keys %{ $tool_state->{skills} };
  }
}

# --- one at a time on this computer ----------------------------------------------------------------------------------------

# Claude Code and Codex may start at the same moment; a refresh token used twice ends its connection, so they take turns.
sub enter_lock {
  my ($seconds) = @_;
  ensure_dir($ROOT);
  sysopen(my $fh, File::Spec->catfile($ROOT, 'lock'), O_RDWR | O_CREAT, 0600) or return undef;
  my $until = time + $seconds;
  while (!flock($fh, LOCK_EX | LOCK_NB)) { return undef if time >= $until; sleep 0.15; }
  return $fh;
}

if ($command eq 'hook') {
  # A hook never stops the session: whatever goes wrong, the session starts with the skills as they are.
  my $output = eval {
    # A report a prompt's sync left is older than this session's start: the session starts with the skills as they are now.
    unlink prompt_file($argument, 'json');
    my $folder = session_folder();
    my $lock = enter_lock(4);
    my $result;
    if ($lock) { $result = sync_tool($argument, $folder); close $lock; }
    # Another session is syncing: this one is given the instructions last received, and nothing else.
    else { $result = { changes => [], notes => [], instructions => instruction_text(session_instructions($folder, [])) }; }
    my $text = hook_text($argument, $result);
    return '' unless length $text;
    my %said = (hookEventName => 'SessionStart', additionalContext => $text);
    $said{reloadSkills} = JSON::PP::true if $argument eq 'claude' && @{ $result->{changes} };
    return $ASCII->encode({ hookSpecificOutput => \%said });
  };
  if (!defined $output) { log_line("hook: $@"); exit 0; }
  print $output;
  exit 0;
} elsif ($command eq 'prompt') {
  # At a prompt, when the sh launcher is not used: the same as the launcher. What a sync in the background found is given
  # once; a new one starts in the background PROMPT_MINUTES after the last.
  exit 0 unless ($argument // '') =~ /^(?:claude|codex)$/;
  my $report = prompt_file($argument, 'json'), my $mark = prompt_file($argument, 'mark');
  if (-f $report) { my $bytes = read_bytes($report); print $bytes if defined $bytes; unlink $report; }
  exit 0 if -f $mark && (-M $mark) * 1440 < $PROMPT_MINUTES;
  set_prompt_mark($argument);
  my $pid = fork();
  if (defined $pid && $pid == 0) {
    eval { require POSIX; POSIX::setsid(); };
    open(STDIN, '<', File::Spec->devnull); open(STDOUT, '>', File::Spec->devnull); open(STDERR, '>', File::Spec->devnull);
    exec($^X, $0, 'prompt-run', $argument) or exit 0;
  }
  exit 0;
} elsif ($command eq 'prompt-run') {
  # The sync of a prompt, in the background: what changed in the Stack during the conversation is written for the next
  # prompt. The instructions were given at the session's start and are left out.
  exit 0 unless ($argument // '') =~ /^(?:claude|codex)$/;
  my $written = eval {
    my $lock = enter_lock(10);
    return 0 unless $lock;
    my $result = sync_tool($argument, '');
    close $lock;
    $result->{instructions} = '';
    my $text = hook_text($argument, $result, 'during this conversation');
    return 0 unless length $text;
    my $report = prompt_file($argument, 'json');
    write_bytes("$report.tmp", $ASCII->encode({ hookSpecificOutput => { hookEventName => 'UserPromptSubmit', additionalContext => $text } }));
    rename("$report.tmp", $report);
    return 1;
  };
  log_line("prompt-run: $@") unless defined $written;
  exit 0;
} elsif ($command eq 'connect') {
  my $lock = enter_lock(30);
  connect_workspace();
} elsif ($command eq 'disconnect') {
  my $lock = enter_lock(30);
  disconnect_workspace($argument);
} elsif ($command eq 'status') {
  show_status();
} elsif ($command eq 'assign' || $command eq 'unassign') {
  my $lock = enter_lock(30);
  set_folder($argument, $rest[0], $command eq 'assign');
} else {
  print "Usage: intellite-sync hook claude|codex | prompt claude|codex | prompt-run claude|codex | connect | status | disconnect <id> | assign <id> <folder> | unassign <id> <folder>\n";
  exit 2;
}
