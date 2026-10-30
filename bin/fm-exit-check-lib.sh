# shellcheck shell=bash
# Private exit-check receipts, owned by fm-control.sh. No activation setting.
# fm_exit_check_begin <state-dir> <task-id> chooses a same-directory staging
# name; fm_exit_check_open <stage> creates it exclusively at mode 0600 on fd 9.
# fm_exit_check_finish <stage> <state-dir> <id> <classification> <dialog yes|no>
#                      <started epoch> <elapsed seconds>
# atomically replaces <state-dir>/<id>.exit-check with an allowlisted receipt.
# No text, hashes of text, stderr, environment, or dialog names are accepted.
# Outcome describes the input guard, never agent stop or replacement.
# Unsafe paths/permissions, malformed diagnostics and I/O errors refuse receipt
# publication only. Callers must ignore receipt failure, never alter a verdict,
# repeat a probe, or delay input to obtain a receipt. Staging cleanup is theirs.
# The wire format is key=value: schema=exit-check-v1, outcome=pass|refuse,
# classification=empty|pending|pending-unproven|unknown, dialog=yes|no,
# capture=ansi|plain|failed|unreported, shape=pi|box|bare|leftbar|unrecognized,
# input=blank|nonblank|unrecognized, native_agent=pi|polytoken|other|unreported,
# native_status=idle|done|working|blocked|other|error|unreported, pair_valid=0|1,
# and nonnegative started_epoch/check_seconds/capture_seconds/identity_seconds.
# Missing adapter details remain unreported/unrecognized, never inferred safe.

fm_exit_check_begin() {
  local dir=$1 id=$2 stage
  case "$id" in ''|*[!A-Za-z0-9._-]*|.|..) return 1 ;; esac
  perl -MCwd=abs_path -e '
    my ($d,$id)=@ARGV; my @s=lstat($d);
    exit 1 unless @s && -d _ && !-l _ && $s[4]==$< && !($s[2]&0022);
    exit 1 unless abs_path($d) eq $d;
    my $p="$d/$id.exit-check";
    if (my @f=lstat($p)) {
      exit 1 unless -f _ && !-l _ && $f[3]==1 && $f[4]==$< && ($f[2]&0777)==0600;
    } elsif ($! != 2) { exit 1 }
  ' -- "$dir" "$id" 2>/dev/null || return 1
  stage=$(umask 077; mktemp "$dir/.$id.exit-check.XXXXXX") || return 1
  rm -f -- "$stage" || return 1
  printf '%s\n' "$stage"
}

# noclobber supplies exclusive creation, including refusal of dangling links.
# Restore the caller's shell settings before it performs the original read.
fm_exit_check_open() {
  local stage=$1 prior_mask prior_noclobber=no result=1
  prior_mask=$(umask)
  case "$-" in *C*) prior_noclobber=yes ;; esac
  umask 077
  set -C
  if { exec 9>"$stage"; } 2>/dev/null; then result=0; fi
  [ "$prior_noclobber" = yes ] || set +C
  umask "$prior_mask"
  return "$result"
}

fm_exit_check_finish() {
  perl -MCwd=abs_path -MFcntl=O_RDONLY,O_NOFOLLOW -MFile::Temp=tempfile -e '
    my ($stage,$dir,$id,$classification,$dialog,$epoch,$elapsed)=@ARGV;
    exit 1 unless $id =~ /\A[A-Za-z0-9._-]+\z/ && $id ne "." && $id ne "..";
    exit 1 unless $classification =~ /\A(?:empty|pending|pending-unproven|unknown)\z/;
    exit 1 unless $dialog =~ /\A(?:yes|no)\z/;
    exit 1 unless $epoch =~ /\A[0-9]{1,12}\z/ && $elapsed =~ /\A[0-9]{1,5}\z/ && $elapsed<=86400;
    my @d=lstat($dir);
    exit 1 unless @d && -d _ && !-l _ && $d[4]==$< && !($d[2]&0022) && abs_path($dir) eq $dir;
    exit 1 unless $stage =~ /\A\Q$dir\E\/\.\Q$id\E\.exit-check\.[A-Za-z0-9]+\z/;
    my @s=lstat($stage);
    exit 1 unless @s && -f _ && !-l _ && $s[3]==1 && $s[4]==$< && ($s[2]&0777)==0600 && $s[7]<=8192;
    sysopen(my $in,$stage,O_RDONLY|O_NOFOLLOW) or exit 1;
    my @opened=stat($in); exit 1 unless $opened[0]==$s[0] && $opened[1]==$s[1];
    my %v=(capture=>"unreported",shape=>"unrecognized",input=>"unrecognized",native_agent=>"unreported",native_status=>"unreported",pair_valid=>0,capture_seconds=>0,identity_seconds=>0);
    my %enum=(capture=>qr/\A(?:ansi|plain|failed)\z/,shape=>qr/\A(?:pi|box|bare|leftbar|unrecognized)\z/,input=>qr/\A(?:blank|nonblank|unrecognized)\z/,native_agent=>qr/\A(?:pi|polytoken|other)\z/,native_status=>qr/\A(?:idle|done|working|blocked|other|error)\z/,pair_valid=>qr/\A[01]\z/,capture_seconds=>qr/\A[0-9]{1,5}\z/,identity_seconds=>qr/\A[0-9]{1,5}\z/);
    my $read_bytes=0;
    while (my $line=<$in>) {
      $read_bytes+=length($line); exit 1 if $read_bytes>8192;
      exit 1 unless $line =~ /\A([a-z_]+)=([^\r\n\x00-\x1f\x7f]*)\n\z/;
      my ($k,$value)=($1,$2); exit 1 unless exists $enum{$k} && $value =~ $enum{$k};
      exit 1 if $k =~ /_seconds\z/ && $value>86400;
      $v{$k}=$value;
    }
    close($in) or exit 1;
    $v{input}="blank" if $classification eq "empty";
    $v{input}="nonblank" if $classification eq "pending" || $classification eq "pending-unproven";
    my $target="$dir/$id.exit-check";
    sub target_safe {
      if (my @f=lstat($target)) { return -f _ && !-l _ && $f[3]==1 && $f[4]==$< && ($f[2]&0777)==0600 }
      return $! == 2;
    }
    exit 1 unless target_safe();
    my ($out,$tmp)=tempfile(".$id.exit-receipt.XXXXXX",DIR=>$dir,UNLINK=>0);
    my $ok=eval {
      chmod(0600,$tmp)==1 or die;
      print $out "schema=exit-check-v1\noutcome=",($classification eq "empty" && $dialog eq "no" ? "pass" : "refuse"),"\nclassification=$classification\ndialog=$dialog\nstarted_epoch=$epoch\ncheck_seconds=$elapsed\n" or die;
      for my $k (qw(capture shape input native_agent native_status pair_valid capture_seconds identity_seconds)) { print $out "$k=$v{$k}\n" or die }
      close($out) or die;
      target_safe() or die;
      my @now=lstat($dir); $now[0]==$d[0] && $now[1]==$d[1] && !-l _ && !($now[2]&0022) or die;
      rename($tmp,$target) or die;
      1;
    };
    unlink($tmp) unless $ok;
    exit($ok ? 0 : 1);
  ' -- "$@" 2>/dev/null
}
